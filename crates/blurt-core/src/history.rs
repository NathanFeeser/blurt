//! Local dictation history.
//!
//! Every dictation is a `(raw ASR, final text)` pair produced by a known mode in
//! a known app. Keeping those is what makes "re-run that with a different
//! prompt", "undo what you just inserted", and eventually the correction
//! correction flywheel possible later. It lives in the core, not the shells,
//! so there is one schema rather than three and a history file written on a Mac
//! reads on Windows.
//!
//! **Text only, deliberately.** No audio is ever written to disk. Re-running an
//! entry re-runs the *cleanup* stage over the stored transcript; re-transcribing
//! is not possible without the audio, and that trade buys a privacy story we can
//! state in one sentence to someone about to grant accessibility access.
//!
//! Storage is still the user's own words in plaintext on their disk, so the
//! shells own three controls over it: a global off switch, a per-mode
//! `record_history` flag (the Private preset turns it off), and a retention cap
//! enforced on every write.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::context::AppContext;
use crate::error::{DictError, Result};
use crate::mode::Mode;
use crate::pipeline::DictationResult;

/// Dictation and command mode produce the same shape of record but answer
/// different questions of it, so they are distinguishable rather than mixed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EntryKind {
    Dictation,
    Command,
}

impl EntryKind {
    fn as_str(self) -> &'static str {
        match self {
            EntryKind::Dictation => "dictation",
            EntryKind::Command => "command",
        }
    }

    fn from_str(s: &str) -> Self {
        match s {
            "command" => EntryKind::Command,
            _ => EntryKind::Dictation,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HistoryEntry {
    pub id: i64,
    /// Unix seconds. The shells format it; the core does not carry a date
    /// library across the FFI boundary for the sake of a menu label.
    pub created_at: i64,
    pub kind: EntryKind,
    pub mode_id: String,
    pub mode_name: String,
    /// Straight from the ASR. This is the column re-run reads.
    pub raw_text: String,
    /// What was actually inserted.
    pub final_text: String,
    /// What the user turned it into afterwards.
    ///
    /// Nothing writes this yet — capturing post-insertion edits is its own
    /// feature. The column exists now because it is the correction pair Phase 6
    /// trains on, and adding it later means migrating everyone's history.
    pub edited_text: Option<String>,
    pub app_bundle_id: Option<String>,
    pub app_name: Option<String>,
    pub stt_provider: String,
    pub stt_model: String,
    pub cleanup_ran: bool,
    pub cleanup_error: Option<String>,
    pub audio_duration_ms: u64,
    pub stt_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
    /// `accessibility` or `paste`, once the shell reports which one landed.
    /// Only the shell knows, so it arrives after the row is written.
    pub insertion_method: Option<String>,
}

/// How many entries to keep. Pruned on every write, so the file cannot grow
/// without bound while nobody is looking.
pub const DEFAULT_LIMIT: u32 = 1000;

pub struct History {
    conn: Mutex<Connection>,
    limit: u32,
}

impl History {
    /// Open (creating if needed) the history database at `path`.
    ///
    /// The shell chooses the location — Application Support on macOS, the App
    /// Group container on iOS, AppData on Windows — because only it knows what
    /// the platform considers a sane place for user data.
    pub fn open(path: &str, limit: u32) -> Result<Self> {
        if let Some(parent) = Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| DictError::Storage {
                    detail: format!("could not create {}: {e}", parent.display()),
                })?;
            }
        }
        let conn = Connection::open(path).map_err(storage)?;
        Self::from_connection(conn, limit)
    }

    /// An in-memory store. Used by the tests, and a reasonable answer for a
    /// shell that wants the API without the file.
    pub fn in_memory(limit: u32) -> Result<Self> {
        Self::from_connection(Connection::open_in_memory().map_err(storage)?, limit)
    }

    fn from_connection(conn: Connection, limit: u32) -> Result<Self> {
        // WAL keeps a read for the history window from blocking the write at the
        // end of a dictation, which is the one moment latency is being measured.
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(storage)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS entries (
                 id                INTEGER PRIMARY KEY AUTOINCREMENT,
                 created_at        INTEGER NOT NULL,
                 kind              TEXT    NOT NULL,
                 mode_id           TEXT    NOT NULL,
                 mode_name         TEXT    NOT NULL,
                 raw_text          TEXT    NOT NULL,
                 final_text        TEXT    NOT NULL,
                 edited_text       TEXT,
                 app_bundle_id     TEXT,
                 app_name          TEXT,
                 stt_provider      TEXT    NOT NULL,
                 stt_model         TEXT    NOT NULL,
                 cleanup_ran       INTEGER NOT NULL,
                 cleanup_error     TEXT,
                 audio_duration_ms INTEGER NOT NULL,
                 stt_ms            INTEGER NOT NULL,
                 cleanup_ms        INTEGER NOT NULL,
                 total_ms          INTEGER NOT NULL,
                 insertion_method  TEXT
             );
             CREATE INDEX IF NOT EXISTS entries_created_at ON entries (created_at DESC);",
        )
        .map_err(storage)?;
        Ok(Self {
            conn: Mutex::new(conn),
            limit: limit.max(1),
        })
    }

    /// Write a finished dictation, returning its id. Prunes to the retention
    /// cap in the same transaction.
    pub fn record(
        &self,
        result: &DictationResult,
        ctx: &AppContext,
        kind: EntryKind,
    ) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO entries (
                 created_at, kind, mode_id, mode_name, raw_text, final_text,
                 app_bundle_id, app_name, stt_provider, stt_model,
                 cleanup_ran, cleanup_error, audio_duration_ms,
                 stt_ms, cleanup_ms, total_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
            params![
                now_secs(),
                kind.as_str(),
                result.mode_id,
                result.mode_name,
                result.raw_text,
                result.final_text,
                ctx.bundle_id,
                ctx.app_name,
                result.stt_provider,
                result.stt_model,
                result.cleanup_ran,
                result.cleanup_error,
                // SQLite integers are signed 64-bit; the millisecond counters
                // are u64 in the FFI record and have to be narrowed here.
                result.audio_duration_ms as i64,
                result.timings.stt_ms as i64,
                result.timings.cleanup_ms as i64,
                result.timings.total_ms as i64,
            ],
        )
        .map_err(storage)?;
        let id = conn.last_insert_rowid();

        // Oldest-first, by id rather than timestamp: a clock that jumps
        // backwards would otherwise make the newest rows look like the oldest.
        conn.execute(
            "DELETE FROM entries WHERE id NOT IN
                 (SELECT id FROM entries ORDER BY id DESC LIMIT ?1)",
            params![self.limit],
        )
        .map_err(storage)?;
        Ok(id)
    }

    pub fn recent(&self, limit: u32) -> Result<Vec<HistoryEntry>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT * FROM entries ORDER BY id DESC LIMIT ?1")
            .map_err(storage)?;
        let rows = stmt
            .query_map(params![limit], row_to_entry)
            .map_err(storage)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(storage)
    }

    /// Substring search over both texts. Deliberately not FTS: at a thousand
    /// rows `LIKE` is instant, and FTS would be a second schema to migrate.
    pub fn search(&self, query: &str, limit: u32) -> Result<Vec<HistoryEntry>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return self.recent(limit);
        }
        // Escape the wildcards so searching for "100%" finds "100%".
        let pattern = format!(
            "%{}%",
            trimmed
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_")
        );
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT * FROM entries
                 WHERE final_text LIKE ?1 ESCAPE '\\' OR raw_text LIKE ?1 ESCAPE '\\'
                 ORDER BY id DESC LIMIT ?2",
            )
            .map_err(storage)?;
        let rows = stmt
            .query_map(params![pattern, limit], row_to_entry)
            .map_err(storage)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(storage)
    }

    pub fn get(&self, id: i64) -> Result<Option<HistoryEntry>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT * FROM entries WHERE id = ?1",
            params![id],
            row_to_entry,
        )
        .optional()
        .map_err(storage)
    }

    /// Record which insertion strategy actually landed. Only the shell knows.
    pub fn note_insertion(&self, id: i64, method: &str) -> Result<()> {
        self.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE entries SET insertion_method = ?2 WHERE id = ?1",
                params![id, method],
            )
            .map(|_| ())
            .map_err(storage)
    }

    /// Record what the user turned the inserted text into. The Phase 6 training
    /// pair; unused until something captures post-insertion edits.
    pub fn record_edit(&self, id: i64, edited: &str) -> Result<()> {
        self.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE entries SET edited_text = ?2 WHERE id = ?1",
                params![id, edited],
            )
            .map(|_| ())
            .map_err(storage)
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM entries WHERE id = ?1", params![id])
            .map(|_| ())
            .map_err(storage)
    }

    /// Delete everything and hand the disk space back.
    ///
    /// `VACUUM` matters here: without it the deleted text stays in the file's
    /// free pages, and "clear my history" that leaves the words recoverable is
    /// not what the user asked for.
    pub fn clear(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM entries", []).map_err(storage)?;
        conn.execute("VACUUM", []).map_err(storage)?;
        Ok(())
    }

    pub fn count(&self) -> Result<u32> {
        self.conn
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM entries", [], |r| {
                r.get::<_, i64>(0).map(|n| n as u32)
            })
            .map_err(storage)
    }
}

fn row_to_entry(row: &Row<'_>) -> rusqlite::Result<HistoryEntry> {
    Ok(HistoryEntry {
        id: row.get("id")?,
        created_at: row.get("created_at")?,
        kind: EntryKind::from_str(&row.get::<_, String>("kind")?),
        mode_id: row.get("mode_id")?,
        mode_name: row.get("mode_name")?,
        raw_text: row.get("raw_text")?,
        final_text: row.get("final_text")?,
        edited_text: row.get("edited_text")?,
        app_bundle_id: row.get("app_bundle_id")?,
        app_name: row.get("app_name")?,
        stt_provider: row.get("stt_provider")?,
        stt_model: row.get("stt_model")?,
        cleanup_ran: row.get("cleanup_ran")?,
        cleanup_error: row.get("cleanup_error")?,
        audio_duration_ms: row.get::<_, i64>("audio_duration_ms")? as u64,
        stt_ms: row.get::<_, i64>("stt_ms")? as u64,
        cleanup_ms: row.get::<_, i64>("cleanup_ms")? as u64,
        total_ms: row.get::<_, i64>("total_ms")? as u64,
        insertion_method: row.get("insertion_method")?,
    })
}

fn storage(e: rusqlite::Error) -> DictError {
    DictError::Storage {
        detail: e.to_string(),
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Whether a finished dictation should be written down at all.
///
/// Split out as a free function because it is the rule the privacy promise
/// rests on, and it is worth being able to test it without a database: a mode
/// that opts out is never recorded, and an empty result is not worth a row.
pub fn should_record(mode: &Mode, result: &DictationResult) -> bool {
    mode.record_history && !result.final_text.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::Timings;

    fn ctx() -> AppContext {
        AppContext {
            bundle_id: Some("com.tinyspeck.slackmacgap".into()),
            app_name: Some("Slack".into()),
            window_title: None,
            surrounding_text: None,
            selected_text: None,
        }
    }

    fn result(final_text: &str) -> DictationResult {
        DictationResult {
            entry_id: None,
            mode_id: "default".into(),
            mode_name: "Dictation".into(),
            raw_text: format!("um {final_text}"),
            final_text: final_text.into(),
            cleanup_ran: true,
            cleanup_error: None,
            audio_duration_ms: 2000,
            detected_language: Some("en".into()),
            stt_provider: "groq".into(),
            stt_model: "whisper-large-v3-turbo".into(),
            timings: Timings {
                stt_ms: 400,
                cleanup_ms: 300,
                total_ms: 700,
            },
        }
    }

    #[test]
    fn records_and_reads_back_every_field() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        let id = h
            .record(&result("ship it"), &ctx(), EntryKind::Dictation)
            .unwrap();

        let entry = h.get(id).unwrap().expect("entry should exist");
        assert_eq!(entry.final_text, "ship it");
        assert_eq!(entry.raw_text, "um ship it");
        assert_eq!(entry.mode_name, "Dictation");
        assert_eq!(entry.app_name.as_deref(), Some("Slack"));
        assert_eq!(entry.stt_provider, "groq");
        assert!(entry.cleanup_ran);
        assert_eq!(entry.total_ms, 700);
        assert_eq!(entry.kind, EntryKind::Dictation);
        assert!(entry.created_at > 0);
        // Nothing captures post-insertion edits yet; the column is reserved.
        assert!(entry.edited_text.is_none());
    }

    #[test]
    fn newest_entries_come_back_first() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        for text in ["first", "second", "third"] {
            h.record(&result(text), &ctx(), EntryKind::Dictation)
                .unwrap();
        }
        let texts: Vec<_> = h
            .recent(10)
            .unwrap()
            .into_iter()
            .map(|e| e.final_text)
            .collect();
        assert_eq!(texts, vec!["third", "second", "first"]);
    }

    #[test]
    fn retention_cap_drops_the_oldest_on_write() {
        let h = History::in_memory(3).unwrap();
        for text in ["a", "b", "c", "d", "e"] {
            h.record(&result(text), &ctx(), EntryKind::Dictation)
                .unwrap();
        }
        assert_eq!(h.count().unwrap(), 3);
        let texts: Vec<_> = h
            .recent(10)
            .unwrap()
            .into_iter()
            .map(|e| e.final_text)
            .collect();
        assert_eq!(texts, vec!["e", "d", "c"]);
    }

    #[test]
    fn search_matches_the_raw_transcript_too() {
        // The point of keeping both: you remember what you *said*, which is not
        // always what cleanup wrote down.
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        h.record(&result("ship it"), &ctx(), EntryKind::Dictation)
            .unwrap();

        assert_eq!(h.search("ship", 10).unwrap().len(), 1);
        assert_eq!(h.search("um ship", 10).unwrap().len(), 1);
        assert_eq!(h.search("nothing like this", 10).unwrap().len(), 0);
        // An empty query is the unfiltered list, not zero results.
        assert_eq!(h.search("   ", 10).unwrap().len(), 1);
    }

    #[test]
    fn search_treats_wildcards_as_literal_text() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        h.record(&result("100% done"), &ctx(), EntryKind::Dictation)
            .unwrap();
        h.record(&result("nowhere near"), &ctx(), EntryKind::Dictation)
            .unwrap();

        // Unescaped, "%" is "match anything" and would return both rows.
        let hits = h.search("100%", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].final_text, "100% done");
    }

    #[test]
    fn insertion_method_and_edits_land_on_the_right_row() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        let id = h
            .record(&result("ship it"), &ctx(), EntryKind::Dictation)
            .unwrap();
        let other = h
            .record(&result("other"), &ctx(), EntryKind::Dictation)
            .unwrap();

        h.note_insertion(id, "paste").unwrap();
        h.record_edit(id, "Ship it!").unwrap();

        let entry = h.get(id).unwrap().unwrap();
        assert_eq!(entry.insertion_method.as_deref(), Some("paste"));
        assert_eq!(entry.edited_text.as_deref(), Some("Ship it!"));
        let untouched = h.get(other).unwrap().unwrap();
        assert!(untouched.insertion_method.is_none());
        assert!(untouched.edited_text.is_none());
    }

    #[test]
    fn delete_and_clear_remove_entries() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        let id = h
            .record(&result("one"), &ctx(), EntryKind::Dictation)
            .unwrap();
        h.record(&result("two"), &ctx(), EntryKind::Dictation)
            .unwrap();

        h.delete(id).unwrap();
        assert_eq!(h.count().unwrap(), 1);
        assert!(h.get(id).unwrap().is_none());

        h.clear().unwrap();
        assert_eq!(h.count().unwrap(), 0);
    }

    #[test]
    fn command_entries_are_distinguishable_from_dictations() {
        let h = History::in_memory(DEFAULT_LIMIT).unwrap();
        h.record(&result("rewritten"), &ctx(), EntryKind::Command)
            .unwrap();
        assert_eq!(h.recent(1).unwrap()[0].kind, EntryKind::Command);
    }

    #[test]
    fn a_mode_that_opts_out_is_never_recorded() {
        // The privacy promise: a mode chosen for privacy leaves no trace on disk.
        let mut private = Mode::default_dictation();
        private.record_history = false;
        assert!(!should_record(&private, &result("secret")));
        assert!(should_record(&Mode::default_dictation(), &result("fine")));
    }

    #[test]
    fn empty_results_are_not_worth_a_row() {
        assert!(!should_record(&Mode::default_dictation(), &result("   ")));
    }

    #[test]
    fn a_file_backed_store_survives_reopening() {
        let dir = std::env::temp_dir().join(format!("blurt-history-{}", std::process::id()));
        let path = dir.join("nested").join("history.sqlite3");
        let path_str = path.to_string_lossy().to_string();
        let _ = std::fs::remove_dir_all(&dir);

        {
            let h = History::open(&path_str, DEFAULT_LIMIT).unwrap();
            h.record(&result("persisted"), &ctx(), EntryKind::Dictation)
                .unwrap();
        }
        let reopened = History::open(&path_str, DEFAULT_LIMIT).unwrap();
        assert_eq!(reopened.recent(10).unwrap()[0].final_text, "persisted");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
