use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

use tokio::fs::{self, File};

static INCOMING_SEQ: AtomicU64 = AtomicU64::new(0);

pub struct DiskCache {
    objects: PathBuf,
    incoming: PathBuf,
    budget: u64,
    used: AtomicU64,
}

pub struct Incoming {
    pub path: PathBuf,
    file: Option<File>,
    persist: bool,
}

impl Incoming {
    pub fn file(&mut self) -> &mut File {
        self.file.as_mut().expect("incoming file")
    }

    pub async fn close(&mut self) -> io::Result<()> {
        if let Some(file) = self.file.as_mut() {
            use tokio::io::AsyncWriteExt;
            file.flush().await?;
            file.sync_all().await?;
        }
        self.file.take();
        Ok(())
    }

    pub fn take_file(&mut self) -> Option<File> {
        self.file.take()
    }

    pub fn persist(&mut self) {
        self.persist = true;
    }
}

impl Drop for Incoming {
    fn drop(&mut self) {
        self.file.take();
        if !self.persist {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

impl DiskCache {
    pub async fn open(root: PathBuf, budget: u64) -> io::Result<Self> {
        let objects = root.join("objects");
        let incoming = root.join("incoming");
        fs::create_dir_all(&objects).await?;
        fs::create_dir_all(&incoming).await?;
        sweep_dir(&incoming).await?;
        let used = scan_size(&objects).await?;
        Ok(Self {
            objects,
            incoming,
            budget,
            used: AtomicU64::new(used),
        })
    }

    pub fn budget(&self) -> u64 {
        self.budget
    }

    pub fn used(&self) -> u64 {
        self.used.load(Ordering::Relaxed)
    }

    pub fn object_path(&self, hash_b58: &str, obao: bool) -> PathBuf {
        if obao {
            self.objects.join(format!("{hash_b58}.obao"))
        } else {
            self.objects.join(hash_b58)
        }
    }

    pub async fn get(&self, hash_b58: &str, obao: bool) -> Option<PathBuf> {
        let path = self.object_path(hash_b58, obao);
        match fs::metadata(&path).await {
            Ok(meta) if meta.is_file() => {
                touch_accessed(&path);
                Some(path)
            }
            _ => None,
        }
    }

    pub async fn create_incoming(&self) -> io::Result<Incoming> {
        let seq = INCOMING_SEQ.fetch_add(1, Ordering::Relaxed);
        let name = format!("{}-{seq}", std::process::id());
        let path = self.incoming.join(name);
        let file = File::create(&path).await?;
        Ok(Incoming {
            path,
            file: Some(file),
            persist: false,
        })
    }

    /// Rename an incoming file into `objects/` after B2 accept (or a
    /// successful B2 GET fill). Drops objects larger than the budget
    /// instead of retaining them.
    pub async fn promote(
        &self,
        incoming: &mut Incoming,
        hash_b58: &str,
        obao: bool,
        len: u64,
    ) -> io::Result<Option<PathBuf>> {
        incoming.close().await?;
        let dest = self.object_path(hash_b58, obao);
        if fs::metadata(&dest).await.is_ok() {
            let _ = fs::remove_file(&incoming.path).await;
            incoming.persist();
            return Ok(Some(dest));
        }
        if len > self.budget {
            let _ = fs::remove_file(&incoming.path).await;
            incoming.persist();
            return Ok(None);
        }
        self.evict_to_fit(len).await?;
        fs::rename(&incoming.path, &dest).await?;
        incoming.persist();
        self.used.fetch_add(len, Ordering::Relaxed);
        Ok(Some(dest))
    }

    /// Keep a GET-miss fill if it fits the budget; otherwise drop it.
    /// Evicts LRU objects so `used + len` stays ≤ budget.
    pub async fn commit_fill(
        &self,
        path: &Path,
        hash_b58: &str,
        obao: bool,
        len: u64,
    ) -> io::Result<Option<PathBuf>> {
        let dest = self.object_path(hash_b58, obao);
        if fs::metadata(&dest).await.is_ok() {
            let _ = fs::remove_file(path).await;
            return Ok(Some(dest));
        }
        if len > self.budget {
            let _ = fs::remove_file(path).await;
            return Ok(None);
        }
        self.evict_to_fit(len).await?;
        fs::rename(path, &dest).await?;
        self.used.fetch_add(len, Ordering::Relaxed);
        Ok(Some(dest))
    }

    async fn evict_to_fit(&self, need: u64) -> io::Result<()> {
        let mut used = self.used.load(Ordering::Relaxed);
        if used.saturating_add(need) <= self.budget {
            return Ok(());
        }
        let mut entries: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
        let mut rd = fs::read_dir(&self.objects).await?;
        while let Some(ent) = rd.next_entry().await? {
            let path = ent.path();
            let meta = match fs::metadata(&path).await {
                Ok(m) if m.is_file() => m,
                _ => continue,
            };
            let accessed = meta.accessed().or_else(|_| meta.modified())?;
            entries.push((accessed, meta.len(), path));
        }
        entries.sort_by_key(|(t, _, _)| *t);
        for (_t, len, path) in entries {
            if used.saturating_add(need) <= self.budget {
                break;
            }
            if fs::remove_file(&path).await.is_ok() {
                used = used.saturating_sub(len);
                self.used.store(used, Ordering::Relaxed);
            }
        }
        Ok(())
    }
}

async fn sweep_dir(dir: &Path) -> io::Result<()> {
    let mut rd = fs::read_dir(dir).await?;
    while let Some(ent) = rd.next_entry().await? {
        let path = ent.path();
        if path.is_file() {
            let _ = fs::remove_file(path).await;
        }
    }
    Ok(())
}

async fn scan_size(dir: &Path) -> io::Result<u64> {
    let mut total = 0u64;
    let mut rd = fs::read_dir(dir).await?;
    while let Some(ent) = rd.next_entry().await? {
        if let Ok(meta) = fs::metadata(ent.path()).await {
            if meta.is_file() {
                total = total.saturating_add(meta.len());
            }
        }
    }
    Ok(total)
}

fn touch_accessed(path: &Path) {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let file = std::fs::File::open(&path)?;
        let times = std::fs::FileTimes::new().set_accessed(SystemTime::now());
        file.set_times(times)
    });
}
