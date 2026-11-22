use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use super::{TransferEvent, TransferIssue, TransferProgress, TransferSummary};

#[derive(Clone, Copy, Debug, Default)]
pub struct FileMetrics {
    pub average: Duration,
    pub data_average: Duration,
    pub device_wait_average: Duration,
    pub idle_average: Duration,
}

#[derive(Clone, Copy)]
pub(super) struct FileTiming {
    pub duration: Duration,
    pub data: Duration,
    pub device_wait: Duration,
    pub idle: Option<Duration>,
}

pub(super) struct Reporter {
    events: Mutex<Option<mpsc::UnboundedSender<TransferEvent>>>,
    state: Mutex<State>,
    pub ahead_files: AtomicU32,
    pub ahead_bytes: AtomicU64,
    #[cfg(test)]
    pub read_started: Mutex<Vec<Instant>>,
}

#[derive(Default)]
struct State {
    progress: TransferProgress,
    last: Option<Instant>,
    timings: VecDeque<FileTiming>,
    bytes: VecDeque<(Instant, u64)>,
    total_io: u64,
    copied: u64,
    pending_bytes: u64,
    planned: bool,
    job_timing: Totals,
}

impl Reporter {
    pub fn new(events: mpsc::UnboundedSender<TransferEvent>) -> Self {
        Self {
            events: Mutex::new(Some(events)),
            state: Mutex::new(State::default()),
            ahead_files: AtomicU32::new(0),
            ahead_bytes: AtomicU64::new(0),
            #[cfg(test)]
            read_started: Mutex::new(Vec::new()),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn send(&self, event: TransferEvent) {
        if let Some(events) = &*self
            .events
            .lock()
            .unwrap_or_else(|error| error.into_inner())
        {
            let _ = events.send(event);
        }
    }

    pub fn planned(&self, files_total: u32, bytes_total: u64, subtree_skipped: u32) {
        let mut state = self.state();
        state.planned = true;
        state.progress.files_total = files_total;
        state.progress.files_done = subtree_skipped;
        state.progress.bytes_total = bytes_total;
        self.send(TransferEvent::Planned {
            files_total,
            bytes_total,
        });
    }

    pub fn start(&self, name: &str, size: u64) {
        let mut state = self.state();
        state.progress.current_name = name.into();
        state.progress.current_bytes_done = 0;
        state.progress.current_bytes_total = size;
        let total = state.total_io;
        if state.bytes.is_empty() {
            state.bytes.push_back((Instant::now(), total));
        }
        self.progress(&mut state);
    }

    pub fn chunk(&self, bytes: u64) {
        let mut state = self.state();
        state.progress.current_bytes_done += bytes;
        state.total_io += bytes;
        self.progress(&mut state);
    }

    pub fn complete(&self, copied: bool, bytes: u64) {
        let mut state = self.state();
        state.progress.files_done = state.progress.files_done.saturating_add(1);
        if copied {
            state.copied += bytes;
        }
        state.progress.current_name.clear();
        state.progress.current_bytes_done = 0;
        state.progress.current_bytes_total = 0;
        self.progress(&mut state);
    }

    pub fn handoff(&self, bytes: u64) {
        let mut state = self.state();
        state.pending_bytes = state.pending_bytes.saturating_add(bytes);
        state.progress.current_name.clear();
        state.progress.current_bytes_done = 0;
        state.progress.current_bytes_total = 0;
        self.progress(&mut state);
    }

    pub fn complete_handed_off(&self, copied: bool, copied_bytes: u64, pending_bytes: u64) {
        let mut state = self.state();
        state.progress.files_done = state.progress.files_done.saturating_add(1);
        state.pending_bytes = state.pending_bytes.saturating_sub(pending_bytes);
        if copied {
            state.copied += copied_bytes;
        }
        self.progress(&mut state);
    }

    pub fn paused(&self, paused: bool) {
        let mut state = self.state();
        state.progress.paused = paused;
        self.progress(&mut state);
    }

    pub fn pending_sources(&self, sources: Vec<String>) {
        self.send(TransferEvent::PendingSources(sources));
    }
    pub fn file_done(&self, path: String, source: String, bytes: u64) {
        self.send(TransferEvent::FileDone {
            path,
            source,
            bytes,
        });
    }
    pub fn file_left_out(&self, source: String) {
        self.send(TransferEvent::FileLeftOut { source });
    }
    pub fn issue(&self, issue: TransferIssue) {
        self.send(TransferEvent::Issue(issue));
    }

    pub fn finish(&self, summary: TransferSummary) {
        if let Some(events) = self.events.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = events.send(TransferEvent::Finished(summary));
        }
    }

    pub fn timing(&self, timing: FileTiming) {
        let mut state = self.state();
        if state.timings.len() == 32 {
            state.timings.pop_front();
        }
        state.timings.push_back(timing);
        state.job_timing.push(timing);
    }

    pub fn metrics(&self) -> FileMetrics {
        self.state().job_timing.metrics()
    }

    pub fn tick(&self) {
        self.progress(&mut self.state());
    }

    fn progress(&self, state: &mut State) {
        if !state.planned {
            return;
        }
        let now = Instant::now();
        if state
            .last
            .is_some_and(|last| now - last < Duration::from_millis(100))
        {
            return;
        }
        state.last = Some(now);
        while state
            .bytes
            .front()
            .is_some_and(|(at, _)| now - *at > Duration::from_secs(2))
            && state.bytes.len() > 1
        {
            state.bytes.pop_front();
        }
        let rate = state
            .bytes
            .front()
            .filter(|(at, _)| now > *at)
            .map_or(0, |(at, total)| {
                ((state.total_io - total) as f64 / (now - *at).as_secs_f64()) as u64
            });
        state.bytes.push_back((now, state.total_io));
        let mut timing = Totals::default();
        for &sample in &state.timings {
            timing.push(sample);
        }
        let metrics = timing.metrics();
        let progress = &mut state.progress;
        progress.bytes_done = state.copied + state.pending_bytes + progress.current_bytes_done;
        progress.speed_bytes_per_sec = rate;
        progress.avg_ms_per_file = ms(metrics.average);
        progress.device_wait_ms_avg = ms(metrics.device_wait_average);
        progress.idle_ms_avg = ms(metrics.idle_average);
        progress.read_ahead_files = self.ahead_files.load(Relaxed);
        progress.read_ahead_bytes = self.ahead_bytes.load(Relaxed);
        self.send(TransferEvent::Progress(progress.clone()));
    }
}

#[derive(Default)]
struct Totals {
    files: u32,
    ranged_files: u32,
    elapsed: Duration,
    data: Duration,
    device: Duration,
    idle: Duration,
}

impl Totals {
    fn push(&mut self, sample: FileTiming) {
        self.files += 1;
        self.elapsed += sample.duration;
        self.data += sample.data;
        self.device += sample.device_wait;
        if let Some(idle) = sample.idle {
            self.ranged_files += 1;
            self.idle += idle;
        }
    }

    fn metrics(&self) -> FileMetrics {
        let count = self.files.max(1);
        FileMetrics {
            average: self.elapsed / count,
            data_average: self.data / count,
            device_wait_average: self.device / count,
            idle_average: self.idle / self.ranged_files.max(1),
        }
    }
}

fn ms(duration: Duration) -> u32 {
    duration.as_millis().min(u128::from(u32::MAX)) as u32
}
