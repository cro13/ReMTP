use std::error::Error;
use std::ffi::OsString;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand, ValueEnum};
use remtp_core::transfer::{
    ConflictPolicy, Direction, FileMetrics, TransferEvent, TransferJob, TransferSummary, VerifyMode,
};
use remtp_core::{AccessState, AdbAccess, Device, Engine, RemtpError, UsbMode, UsbModeSwitch};

#[derive(Parser)]
#[command(version, about = "Move files between a computer and an MTP device")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Devices,
    /// Switch an Android device's USB mode (requires USB debugging).
    UsbMode {
        #[arg(value_name = "ID")]
        dev: String,
        mode: UsbModeArg,
    },
    Info {
        dev: String,
    },
    Ls {
        dev: String,
        storage: String,
        path: String,
    },
    Push {
        #[arg(required = true, num_args = 4.., value_name = "LOCAL... DEV STORAGE DEVFOLDER")]
        paths: Vec<OsString>,
    },
    Pull {
        #[arg(required = true, num_args = 4.., value_name = "DEV STORAGE DEVPATH... LOCALDIR")]
        paths: Vec<OsString>,
    },
    Mkdir {
        dev: String,
        storage: String,
        path: String,
    },
    Rm {
        dev: String,
        storage: String,
        path: String,
    },
    Access {
        dev: String,
    },
    Release {
        dev: String,
    },
    Restore,
    Bench {
        dev: String,
        storage: String,
        devfolder: String,
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..))]
        files: u32,
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        size_mb: u64,
        #[arg(long)]
        keep: bool,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum UsbModeArg {
    Mtp,
    Charging,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();
    let engine = Arc::new(Engine::default());
    match cli.command {
        Command::Devices => {
            let mtp = engine.list_devices()?;
            for (index, device) in mtp.iter().enumerate() {
                println!(
                    "{index}\t{}\t{}\t{}\t{}",
                    device.id, device.manufacturer, device.name, device.model
                );
            }
            for (index, device) in engine.list_adb_only_devices()?.into_iter().enumerate() {
                let index = index + mtp.len();
                println!(
                    "{index}\t{}\t{}\t{}\t{}\t(file transfer off; ADB: {})",
                    device.id,
                    device.manufacturer,
                    device.name,
                    device.model,
                    adb_status(device.adb)
                );
            }
        }
        Command::UsbMode { dev, mode } => {
            let id = usb_device_id(&engine, &dev)?;
            let mode = match mode {
                UsbModeArg::Mtp => UsbMode::FileTransfer,
                UsbModeArg::Charging => UsbMode::ChargingOnly,
            };
            match engine.set_usb_mode(&id, mode).await? {
                UsbModeSwitch::Switched {
                    device_id: Some(id),
                } => println!("Switched: {id}"),
                UsbModeSwitch::Switched { device_id: None } => {
                    println!("Switch sent; device didn't reappear in the requested mode in time.");
                }
                UsbModeSwitch::NeedsApproval => {
                    return Err(io::Error::other(
                        "Allow USB debugging on the device and try again.",
                    )
                    .into());
                }
                UsbModeSwitch::Unavailable { reason } => {
                    return Err(io::Error::other(reason).into());
                }
            }
        }
        Command::Info { dev } => {
            let device = engine.open(&device_id(&engine, &dev)?).await?;
            let details = device.details().await?;
            println!("{} ({})", details.summary.name, details.summary.id);
            println!("Manufacturer: {}", details.summary.manufacturer);
            println!("Model: {}", details.summary.model);
            println!(
                "ADB: {}",
                adb_status(engine.adb_access(&details.summary.id))
            );
            println!(
                "Link: {}",
                details.link_speed.as_deref().unwrap_or("unknown")
            );
            for storage in details.storages {
                println!(
                    "{:#010x}\t{}\t{} of {} bytes free{}",
                    storage.id,
                    storage.description,
                    storage.free_bytes,
                    storage.capacity_bytes,
                    if storage.removable {
                        " (removable)"
                    } else {
                        ""
                    }
                );
            }
            device.close().await;
        }
        Command::Ls { dev, storage, path } => {
            let device = engine.open(&device_id(&engine, &dev)?).await?;
            for entry in device.list(storage_id(&storage)?, &path).await? {
                println!(
                    "{}\t{}\t{}\t{}",
                    if entry.is_dir { "dir" } else { "file" },
                    entry.size,
                    entry
                        .modified
                        .map_or_else(|| "-".into(), |time| time.to_string()),
                    entry.name
                );
            }
            device.close().await;
        }
        Command::Push { paths } => copy(&engine, Direction::ToDevice, &paths).await?,
        Command::Pull { paths } => copy(&engine, Direction::FromDevice, &paths).await?,
        Command::Mkdir { dev, storage, path } => {
            let device = engine.open(&device_id(&engine, &dev)?).await?;
            let result = device.create_folder(storage_id(&storage)?, &path).await;
            device.close().await;
            result?;
        }
        Command::Rm { dev, storage, path } => {
            let device = engine.open(&device_id(&engine, &dev)?).await?;
            let result = device.delete(storage_id(&storage)?, &path).await;
            device.close().await;
            result?;
        }
        Command::Access { dev } => match engine.access_state(&device_id(&engine, &dev)?) {
            AccessState::Free => println!("Free"),
            AccessState::HeldBy {
                process,
                pid: Some(pid),
            } => println!("Held by {process} (PID {pid})"),
            AccessState::HeldBy { process, pid: None } => println!("Held by {process}"),
            AccessState::Unknown => println!("Unknown"),
        },
        Command::Release { dev } => {
            let id = device_id(&engine, &dev)?;
            engine.release_system_hold(&id).await?;
            #[cfg(target_os = "macos")]
            {
                engine.open(&id).await?.close().await;
                println!("Device opened. Run `remtp restore` when you’re done.");
            }
        }
        Command::Restore => engine.restore_system_hold()?,
        Command::Bench {
            dev,
            storage,
            devfolder,
            files,
            size_mb,
            keep,
        } => {
            let device = engine.open(&device_id(&engine, &dev)?).await?;
            let result = bench(
                &device,
                storage_id(&storage)?,
                devfolder,
                files,
                size_mb,
                keep,
            )
            .await;
            device.close().await;
            result?;
        }
    }
    Ok(())
}

fn device_id(engine: &Engine, dev: &str) -> Result<String, RemtpError> {
    let devices = engine.list_devices()?;
    if let Some(device) = devices.iter().find(|item| item.id == dev) {
        return Ok(device.id.clone());
    }
    dev.parse::<usize>()
        .ok()
        .and_then(|index| devices.get(index))
        .map(|device| device.id.clone())
        .ok_or(RemtpError::NoDevice)
}

fn usb_device_id(engine: &Engine, dev: &str) -> Result<String, RemtpError> {
    let index = dev.parse::<usize>().ok();
    let mtp = engine.list_devices()?;
    if let Some(device) = index
        .and_then(|index| mtp.get(index))
        .or_else(|| mtp.iter().find(|device| device.id == dev))
    {
        return Ok(device.id.clone());
    }
    let adb = engine.list_adb_only_devices()?;
    index
        .and_then(|index| index.checked_sub(mtp.len()))
        .and_then(|index| adb.get(index))
        .or_else(|| adb.iter().find(|device| device.id == dev))
        .map(|device| device.id.clone())
        .ok_or(RemtpError::NoDevice)
}

fn adb_status(access: AdbAccess) -> String {
    match access {
        AdbAccess::Off => "off".into(),
        AdbAccess::Ready => "ready".into(),
        AdbAccess::NeedsApproval => "needs approval".into(),
        AdbAccess::Unavailable { reason } => reason,
    }
}

fn storage_id(storage: &str) -> Result<u32, Box<dyn Error>> {
    Ok(
        match storage
            .strip_prefix("0x")
            .or_else(|| storage.strip_prefix("0X"))
        {
            Some(hex) => u32::from_str_radix(hex, 16)?,
            None => storage.parse()?,
        },
    )
}

fn text(value: &std::ffi::OsStr) -> Result<&str, io::Error> {
    value
        .to_str()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path or argument is not UTF-8"))
}

fn absolute(value: &std::ffi::OsStr) -> Result<String, io::Error> {
    let path = std::path::absolute(value)?;
    Ok(text(path.as_os_str())?.into())
}

async fn copy(
    engine: &Engine,
    direction: Direction,
    args: &[OsString],
) -> Result<(), Box<dyn Error>> {
    let (dev, storage, destination, sources) = match direction {
        Direction::ToDevice => {
            let (sources, tail) = args.split_at(args.len() - 3);
            (
                text(&tail[0])?,
                storage_id(text(&tail[1])?)?,
                text(&tail[2])?.into(),
                sources
                    .iter()
                    .map(|path| absolute(path))
                    .collect::<Result<Vec<_>, _>>()?,
            )
        }
        Direction::FromDevice => {
            let (head, tail) = args.split_at(2);
            let (destination, sources) = tail.split_last().unwrap();
            (
                text(&head[0])?,
                storage_id(text(&head[1])?)?,
                absolute(destination)?,
                sources
                    .iter()
                    .map(|path| text(path).map(str::to_owned))
                    .collect::<Result<Vec<_>, _>>()?,
            )
        }
    };
    let device = engine.open(&device_id(engine, dev)?).await?;
    let card_safe_names = device
        .details()
        .await?
        .storages
        .iter()
        .any(|item| item.id == storage && item.removable);
    let result = transfer(
        &device,
        TransferJob {
            direction,
            storage_id: storage,
            sources,
            destination,
            conflict: ConflictPolicy::KeepBoth,
            verify: VerifyMode::None,
            card_safe_names,
        },
        false,
    )
    .await;
    device.close().await;
    let (summary, _, _) = result?;
    println!(
        "{} copied, {} skipped, {} failed, {} bytes in {} ms",
        summary.files_copied,
        summary.files_skipped,
        summary.files_failed,
        summary.bytes,
        summary.elapsed_ms
    );
    outcome(&summary)
}

async fn transfer(
    device: &std::sync::Arc<Device>,
    job: TransferJob,
    collect_copied: bool,
) -> Result<(TransferSummary, FileMetrics, Vec<String>), Box<dyn Error>> {
    let (transfer, mut events) = device.start_transfer(job)?;
    let mut copied = Vec::new();
    while let Some(event) = events.recv().await {
        match event {
            TransferEvent::Planned {
                files_total,
                bytes_total,
            } => eprintln!("Planned {files_total} items, {bytes_total} bytes"),
            TransferEvent::Issue(issue) => eprintln!("{}: {}", issue.path, issue.message),
            TransferEvent::FileDone { path, .. } if collect_copied => copied.push(path),
            TransferEvent::Finished(summary) => return Ok((summary, transfer.metrics(), copied)),
            _ => {}
        }
    }
    Err(io::Error::other("transfer stopped without a summary").into())
}

fn outcome(summary: &TransferSummary) -> Result<(), Box<dyn Error>> {
    if let Some(error) = &summary.error {
        return Err(io::Error::other(error.clone()).into());
    }
    if summary.files_failed != 0 {
        return Err(io::Error::other("some files failed").into());
    }
    Ok(())
}

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

async fn bench(
    device: &std::sync::Arc<Device>,
    storage: u32,
    devfolder: String,
    files: u32,
    size_mb: u64,
    keep: bool,
) -> Result<(), Box<dyn Error>> {
    let details = device.details().await?;
    let bytes = size_mb
        .checked_mul(1_000_000)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "file size overflow"))?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let prefix = format!("remtp-bench-{}-{stamp:x}", std::process::id());
    let path = std::env::temp_dir().join(&prefix);
    std::fs::create_dir(&path)?;
    let temp = TempDir(path);
    let mut sources = Vec::new();
    let mut seed = RandomState::new().hash_one(stamp) | 1;
    let mut buffer = vec![0; 1024 * 1024];
    for index in 0..files {
        let path = temp.0.join(format!("{prefix}-{index}.bin"));
        random_file(&path, bytes, &mut buffer, &mut seed)?;
        sources.push(absolute(path.as_os_str())?);
    }
    let (summary, metrics, copied) = transfer(
        device,
        TransferJob {
            direction: Direction::ToDevice,
            storage_id: storage,
            sources,
            destination: devfolder,
            conflict: ConflictPolicy::Skip,
            verify: VerifyMode::None,
            card_safe_names: false,
        },
        !keep,
    )
    .await?;
    let time = summary.elapsed_ms as f64 / 1000.0;
    println!(
        "{} of {files} files in {time:.3} s: {:.2} MB/s",
        summary.files_copied,
        summary.bytes as f64 / 1e6 / time.max(0.001)
    );
    println!(
        "Avg ms/file: {:.2}; data avg: {:.2}; device-wait avg: {:.2}; idle avg: {:.2}",
        metrics.average.as_secs_f64() * 1000.0,
        metrics.data_average.as_secs_f64() * 1000.0,
        metrics.device_wait_average.as_secs_f64() * 1000.0,
        metrics.idle_average.as_secs_f64() * 1000.0
    );
    println!(
        "Link: {}",
        details.link_speed.as_deref().unwrap_or("unknown")
    );
    let mut cleanup = Ok(());
    for path in copied {
        if let Err(error) = device.delete(storage, &path).await {
            eprintln!("cleanup {path}: {error}");
            cleanup = Err(error);
        }
    }
    outcome(&summary)?;
    cleanup?;
    if summary.files_skipped != 0 {
        return Err(io::Error::other("benchmark skipped existing files").into());
    }
    Ok(())
}

fn random_file(
    path: &Path,
    mut remaining: u64,
    buffer: &mut [u8],
    seed: &mut u64,
) -> io::Result<()> {
    let mut file = BufWriter::new(std::fs::File::create_new(path)?);
    while remaining > 0 {
        let count = remaining.min(buffer.len() as u64) as usize;
        for chunk in buffer[..count].chunks_mut(8) {
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            chunk.copy_from_slice(&seed.to_le_bytes()[..chunk.len()]);
        }
        file.write_all(&buffer[..count])?;
        remaining -= count as u64;
    }
    file.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_variadic_push_and_pull() {
        let push =
            Cli::try_parse_from(["remtp", "push", "a", "b", "0", "0x10001", "/Music"]).unwrap();
        assert!(matches!(push.command, Command::Push { paths } if paths.len() == 5));
        let pull = Cli::try_parse_from(["remtp", "pull", "SERIAL", "1", "/a", "/b", "."]).unwrap();
        assert!(matches!(pull.command, Command::Pull { paths } if paths.len() == 5));
        assert!(Cli::try_parse_from(["remtp", "push", "a", "0", "1"]).is_err());
    }
}
