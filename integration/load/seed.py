#!/usr/bin/env python3
"""Seeds the isolated measurement database with a load-shaped graph.

Why bulk SQL instead of the HTTP API: 200k statuses through `POST /api/v1/statuses`
would spend the whole measurement budget writing, and the point of the first run is
to read it. The rows are written the way the API writes them -- a local status has
`uri IS NULL`, the author's own row and every accepted follower below
`BIG_ACCOUNT_THRESHOLD` get a `timeline_entry`, and `statuses_count`,
`followers_count` and `following_count` are computed from the rows themselves rather
than guessed -- so the read paths under test cannot tell this data apart from posted
data. The one API-shaped thing this cannot reproduce is a remote status (no `uri`,
no `external_id`), and the load scenarios do not read remote statuses.

Idempotent-ish: a rerun deletes the `loadbulk*` accounts first, which cascades to
their statuses, media, follows and timeline rows, and then reinserts them. The one
API-created account (the authenticated load reader) is left alone; its follows,
timeline rows and notifications are rebuilt around the fresh bulk ids.
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

ACCOUNTS = 10_000
STATUSES = 200_000
MEDIA = 20_000
HUBS = 6
POPULAR = 100
MID = 1_000
SPAN_MS = 30 * 24 * 60 * 60 * 1000

SENTENCES = [
    "The public timeline is the cheapest read in the application.",
    "A profile page hydrates one account and its newest statuses.",
    "Fan-out writes one timeline row per follower below the big-account threshold.",
    "This row exists to be read, not to be interesting.",
    "Media bytes come from the media worker, not from the API process.",
    "Pagination walks the status id index backwards.",
    "The home timeline is a Valkey sorted set until it is cold.",
    "Notifications are a second indexed read per page.",
    "Every measurement in the report was produced by reading rows like this one.",
    "A status that nobody replies to keeps its reply count at zero.",
]


def ulid(ms: int, entropy: int) -> str:
    """26-char Crockford base32, the same encoding `ulid::Ulid::new()` produces."""
    value = ((ms & ((1 << 48) - 1)) << 80) | (entropy & ((1 << 80) - 1))
    out = []
    for _ in range(26):
        out.append(CROCKFORD[value & 31])
        value >>= 5
    return "".join(reversed(out))


def iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, UTC).isoformat(
        timespec="milliseconds"
    )


def ent(rng: random.Random) -> int:
    return rng.getrandbits(80)


class Database:
    """psql inside the lab's postgres container, on the measurement database."""

    def __init__(self, container: str, database: str, user: str):
        self.container = container
        self.database = database
        self.user = user

    def run(self, sql: str) -> str:
        proc = subprocess.run(
            [
                "docker",
                "exec",
                "-i",
                self.container,
                "psql",
                "-U",
                self.user,
                "-d",
                self.database,
                "-v",
                "ON_ERROR_STOP=1",
                "-q",
                "-tA",
                "-c",
                sql,
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise SystemExit(f"psql failed: {sql}\n{proc.stderr}")
        return proc.stdout.strip()

    def run_params(self, sql: str, **params: str) -> str:
        """psql variables, set on stdin: the value never becomes SQL text."""
        script = "".join(
            f"\\set {name} '{value}'\n" for name, value in params.items()
        )
        proc = subprocess.run(
            [
                "docker",
                "exec",
                "-i",
                self.container,
                "psql",
                "-U",
                self.user,
                "-d",
                self.database,
                "-v",
                "ON_ERROR_STOP=1",
                "-q",
                "-tA",
                "-f",
                "-",
            ],
            input=script + sql,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise SystemExit(f"psql failed: {sql}\n{proc.stderr}")
        return proc.stdout.strip()

    def copy(self, sql: str, path: Path) -> None:
        with path.open("rb") as handle:
            proc = subprocess.run(
                [
                    "docker",
                    "exec",
                    "-i",
                    self.container,
                    "psql",
                    "-U",
                    self.user,
                    "-d",
                    self.database,
                    "-v",
                    "ON_ERROR_STOP=1",
                    "-q",
                    "-c",
                    sql,
                ],
                stdin=handle,
                capture_output=True,
                text=True,
            )
        if proc.returncode != 0:
            raise SystemExit(f"COPY failed: {sql}\n{proc.stderr}")


def csv_field(value) -> str:
    """CSV as PostgreSQL reads it: quoted text (so '' stays an empty string,
    which the NOT NULL text columns need) and a bare empty field for None
    (which is SQL NULL, the only way to leave a nullable timestamp unset)."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return '"t"' if value else '"f"'
    if isinstance(value, int):
        return str(value)
    text = str(value)
    return '"' + text.replace('"', '""') + '"'


def write_csv(path: Path, header: list[str], rows) -> int:
    count = 0
    with path.open("w", newline="") as handle:
        handle.write(",".join(csv_field(name) for name in header) + "\n")
        for row in rows:
            handle.write(",".join(csv_field(value) for value in row) + "\n")
            count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", default="nodus-lab-postgres")
    parser.add_argument("--database", default="nodusload")
    parser.add_argument("--user", default="nodus")
    parser.add_argument("--accounts", type=int, default=ACCOUNTS)
    parser.add_argument("--statuses", type=int, default=STATUSES)
    parser.add_argument("--media", type=int, default=MEDIA)
    parser.add_argument("--seed", type=int, default=20261123)
    parser.add_argument(
        "--auth-id",
        default="",
        help="API-created account to give a home timeline and notifications",
    )
    parser.add_argument(
        "--media-digest",
        required=True,
        help="sha256 of a file already present in the media worker's NODUS_MEDIA_DIR",
    )
    parser.add_argument("--media-size", type=int, required=True)
    parser.add_argument("--out", type=Path, default=Path("out/seed"))
    args = parser.parse_args()

    rng = random.Random(args.seed)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    db = Database(args.container, args.database, args.user)

    if args.accounts < 1_200:
        raise SystemExit("--accounts must cover the hub/popular/mid bands")
    total_statuses = args.statuses
    media_target = min(args.media, total_statuses)

    print(f"clearing a previous bulk seed in {args.database} ...", flush=True)
    # Delete the children in one bulk statement each before the accounts.
    # `DELETE FROM account` alone cascades row by row, and media_attachment has
    # no index on account_id, so the first rerun spent ten minutes scanning the
    # media table once per account. In bulk, each table is scanned once.
    db.run(
        "DELETE FROM media_attachment WHERE account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%');"
        "DELETE FROM timeline_entry WHERE account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%');"
        "DELETE FROM notification WHERE account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%');"
        "DELETE FROM follow WHERE account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%') "
        "OR target_account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%');"
        "DELETE FROM status WHERE account_id IN "
        "(SELECT id FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%');"
        "DELETE FROM account WHERE domain IS NULL AND username LIKE 'loadbulk%';"
    )
    if args.auth_id:
        db.run_params(
            "DELETE FROM follow WHERE account_id = :'auth_id';\n"
            "DELETE FROM timeline_entry WHERE account_id = :'auth_id';\n"
            "DELETE FROM notification WHERE account_id = :'auth_id';\n",
            auth_id=args.auth_id,
        )

    ids: list[str] = []
    usernames: list[str] = []
    print(f"accounts: {args.accounts}", flush=True)
    base_account_ms = int(time.time() * 1000) - SPAN_MS - 86_400_000

    account_rows = []
    for i in range(args.accounts):
        account_id = ulid(base_account_ms + i * 1000, ent(rng))
        ids.append(account_id)
        usernames.append(f"loadbulk{i:05d}")
        account_rows.append(
            [
                account_id,
                f"loadbulk{i:05d}",
                f"Load account {i}",
                f"Bulk-seeded account {i} of the measurement graph.",
                True,
                iso(base_account_ms + i * 1000),
                iso(base_account_ms + i * 1000),
            ]
        )

    # ---- follow graph ----------------------------------------------------
    # Hubs are followed by almost everybody; popular and mid accounts get
    # random inbound follows from the tail. Account indices are the identity
    # here, so the tail stays mostly below 50 followers even though six
    # accounts are far above it.
    print("follow graph ...", flush=True)
    follows: set[tuple[int, int]] = set()
    for i in range(HUBS, args.accounts):
        # Three hubs are followed by the entire population (well over 5,000
        # each); the rest share the remaining inbound interest. Without the
        # first group the top of the distribution would only reach ~1,700.
        for hub in range(3):
            follows.add((i, hub))
        follows.add((i, 3 + (i % (HUBS - 3))))
        for _ in range(3):
            target = rng.randrange(args.accounts)
            if target != i:
                follows.add((i, target))
    for i in range(HUBS + POPULAR, HUBS + POPULAR + MID):
        for _ in range(18):
            follower = rng.randrange(HUBS + POPULAR + MID, args.accounts)
            if follower != i:
                follows.add((follower, i))

    inbound = [0] * args.accounts
    outgoing = [0] * args.accounts
    for follower, target in follows:
        outgoing[follower] += 1
        inbound[target] += 1

    follow_rows = []
    for follower, target in sorted(follows):
        follow_rows.append(
            [
                ulid(base_account_ms + follower * 1000 + 500, ent(rng)),
                ids[follower],
                ids[target],
                True,
                False,
                iso(base_account_ms + follower * 1000 + 500),
                "accepted",
            ]
        )

    # ---- statuses --------------------------------------------------------
    # Hot authors post often, the tail rarely; timestamps are spread across 30
    # days and a ULID's timestamp prefix is set from the same instant, so
    # ORDER BY id DESC is ORDER BY created_at DESC (the public timeline's index
    # and its cursor both assume this).
    print(f"statuses: {total_statuses}", flush=True)
    weights = [1] * args.accounts
    for i in range(HUBS, HUBS + POPULAR):
        weights[i] = 140
    for i in range(HUBS + POPULAR, HUBS + POPULAR + MID):
        weights[i] = 22
    authors = rng.choices(range(args.accounts), weights=weights, k=total_statuses)
    now_ms = int(time.time() * 1000)
    start_ms = now_ms - SPAN_MS

    timeline_by_author: dict[int, list[tuple[str, int]]] = {}
    status_rows = []
    status_ms: list[int] = []
    status_author: list[int] = []
    for n, author in enumerate(authors):
        ms = start_ms + (n * SPAN_MS) // total_statuses
        status_id = ulid(ms, ent(rng))
        text = f"{rng.choice(SENTENCES)} ({n})"
        status_rows.append(
            [
                status_id,
                ids[author],
                text,
                f"<p>{text}</p>",
                "",
                "public",
                False,
                True,
                iso(ms),
            ]
        )
        status_ms.append(ms)
        status_author.append(author)
        timeline_by_author.setdefault(author, []).append((status_id, ms))
    for rows in timeline_by_author.values():
        rows.sort(key=lambda pair: pair[1], reverse=True)

    # ---- media -----------------------------------------------------------
    # Every tenth status carries one attachment. `processing_state='ready'` and
    # `original_pruned=false` with a digest that names a real file in the media
    # volume is exactly what makes `/media/{id}/compressed` serve bytes; the
    # media worker falls back to the original when no variant exists.
    print(f"media: {media_target}", flush=True)
    media_rows = []
    media_ids: list[str] = []
    media_status_idx = []
    step = max(1, total_statuses // media_target)
    for n in range(0, total_statuses, step):
        if len(media_rows) >= media_target:
            break
        media_id = ulid(status_ms[n] + 1, ent(rng))
        media_ids.append(media_id)
        media_status_idx.append(n)
        media_rows.append(
            [
                media_id,
                ids[status_author[n]],
                status_rows[n][0],
                args.media_digest,
                "image/png",
                args.media_size,
                400,
                400,
                "",
                "{}",
                "ready",
                100,
                iso(status_ms[n]),
                False,
            ]
        )

    # ---- write -----------------------------------------------------------
    account_csv = out / "account.csv"
    follow_csv = out / "follow.csv"
    status_csv = out / "status.csv"
    media_csv = out / "media_attachment.csv"
    write_csv(
        account_csv,
        [
            "id",
            "username",
            "display_name",
            "note",
            "local",
            "created_at",
            "updated_at",
        ],
        account_rows,
    )
    write_csv(
        follow_csv,
        [
            "id",
            "account_id",
            "target_account_id",
            "reblogs",
            "notify",
            "created_at",
            "state",
        ],
        follow_rows,
    )
    write_csv(
        status_csv,
        [
            "id",
            "account_id",
            "content",
            "content_html",
            "spoiler_text",
            "visibility",
            "sensitive",
            "local",
            "created_at",
        ],
        status_rows,
    )
    write_csv(
        media_csv,
        [
            "id",
            "account_id",
            "status_id",
            "digest",
            "content_type",
            "size",
            "width",
            "height",
            "description",
            "meta",
            "processing_state",
            "processing_progress",
            "posted_at",
            "sensitive",
        ],
        media_rows,
    )

    db.copy(
        "COPY account (id, username, display_name, note, local, created_at, updated_at) "
        "FROM STDIN WITH (FORMAT csv, HEADER true)",
        account_csv,
    )
    db.copy(
        "COPY follow (id, account_id, target_account_id, reblogs, notify, created_at, state) "
        "FROM STDIN WITH (FORMAT csv, HEADER true)",
        follow_csv,
    )
    db.copy(
        "COPY status (id, account_id, content, content_html, spoiler_text, visibility, "
        "sensitive, local, created_at) FROM STDIN WITH (FORMAT csv, HEADER true)",
        status_csv,
    )
    db.copy(
        "COPY media_attachment (id, account_id, status_id, digest, content_type, size, "
        "width, height, description, meta, processing_state, processing_progress, "
        "posted_at, sensitive) FROM STDIN WITH (FORMAT csv, HEADER true)",
        media_csv,
    )

    # Counters the read paths and the big-account rule actually consult.
    print("recomputing counters ...", flush=True)
    db.run(
        "UPDATE account a SET followers_count = c.n FROM "
        "(SELECT target_account_id, count(*) AS n FROM follow GROUP BY 1) c "
        "WHERE a.id = c.target_account_id"
    )
    db.run(
        "UPDATE account a SET following_count = c.n FROM "
        "(SELECT account_id, count(*) AS n FROM follow GROUP BY 1) c "
        "WHERE a.id = c.account_id"
    )
    db.run(
        "UPDATE account a SET statuses_count = c.n, last_status_at = c.last "
        "FROM (SELECT account_id, count(*) AS n, max(created_at) AS last "
        "FROM status WHERE deleted_at IS NULL GROUP BY 1) c "
        "WHERE a.id = c.account_id"
    )

    manifest: dict[str, object] = {
        "accounts": args.accounts,
        "statuses": total_statuses,
        "media": len(media_rows),
        "follows": len(follow_rows),
        "hubs": [
            {"index": i, "account_id": ids[i], "followers": inbound[i]}
            for i in range(HUBS)
        ],
        "max_tail_followers": max(inbound[HUBS + POPULAR + MID :]),
    }

    # A representative profile: the busiest mid author, plus its newest status.
    busiest = max(
        range(HUBS + POPULAR, HUBS + POPULAR + MID),
        key=lambda i: len(timeline_by_author.get(i, [])),
    )
    manifest["profile_account_id"] = ids[busiest]
    manifest["profile_username"] = usernames[busiest]
    manifest["profile_status_id"] = timeline_by_author[busiest][0][0]
    manifest["media_id"] = media_ids[0]
    manifest["media_status_id"] = status_rows[media_status_idx[0]][0]
    manifest["newest_status_id"] = status_rows[-1][0]

    if args.auth_id:
        # The authenticated reader follows 40 mid accounts, all below the
        # big-account threshold, so the home timeline has both a warm Valkey
        # path and a SQL fallback that returns the same rows.
        followed = list(range(HUBS + POPULAR, HUBS + POPULAR + 40))
        auth_follow_rows = []
        for i in followed:
            auth_follow_rows.append(
                [
                    ulid(now_ms - 1000, ent(rng)),
                    args.auth_id,
                    ids[i],
                    True,
                    False,
                    iso(now_ms - 1000),
                    "accepted",
                ]
            )
        auth_follow_csv = out / "auth_follow.csv"
        write_csv(
            auth_follow_csv,
            [
                "id",
                "account_id",
                "target_account_id",
                "reblogs",
                "notify",
                "created_at",
                "state",
            ],
            auth_follow_rows,
        )
        db.copy(
            "COPY follow (id, account_id, target_account_id, reblogs, notify, "
            "created_at, state) FROM STDIN WITH (FORMAT csv, HEADER true)",
            auth_follow_csv,
        )
        db.run(
            "UPDATE account a SET following_count = c.n FROM "
            "(SELECT account_id, count(*) AS n FROM follow GROUP BY 1) c "
            "WHERE a.id = c.account_id"
        )

        # Home timeline: the newest 400 statuses of those follows, which is the
        # set `fan_out_home` would have written had these statuses been posted
        # after the follow rows existed.
        timeline_rows = []
        for i in followed:
            for status_id, ms in timeline_by_author.get(i, [])[:10]:
                timeline_rows.append([args.auth_id, status_id, "home", iso(ms)])
        timeline_csv = out / "timeline_entry.csv"
        write_csv(
            timeline_csv,
            ["account_id", "status_id", "kind", "created_at"],
            timeline_rows,
        )
        db.copy(
            "COPY timeline_entry (account_id, status_id, kind, created_at) "
            "FROM STDIN WITH (FORMAT csv, HEADER true)",
            timeline_csv,
        )
        manifest["auth_timeline_rows"] = len(timeline_rows)

        # Notifications: follows, favourites and mentions, all pointing at
        # statuses the reader's follows actually wrote.
        notification_rows = []
        for n in range(400):
            source = followed[n % len(followed)]
            status_id, ms = timeline_by_author[source][n % 10]
            kind = "favourite" if n % 2 == 0 else "mention"
            notification_rows.append(
                [
                    ulid(now_ms - 5000 + n, ent(rng)),
                    args.auth_id,
                    kind,
                    ids[source],
                    status_id,
                    None,
                    iso(now_ms - 5000 + n),
                    1,
                ]
            )
        notification_csv = out / "notification.csv"
        write_csv(
            notification_csv,
            [
                "id",
                "account_id",
                "kind",
                "from_account_id",
                "status_id",
                "seen_at",
                "created_at",
                "group_count",
            ],
            notification_rows,
        )
        db.copy(
            "COPY notification (id, account_id, kind, from_account_id, status_id, "
            "seen_at, created_at, group_count) FROM STDIN WITH (FORMAT csv, HEADER true)",
            notification_csv,
        )
        manifest["auth_notifications"] = len(notification_rows)

        # Warm cache seed: the home cache is a ZSET of status ids scored by the
        # ULID timestamp. `load.sh` pipes this file into valkey-cli.
        warm_lines = [f"DEL home:{args.auth_id}"]
        for status_id, ms in sorted(
            (pair for i in followed for pair in timeline_by_author[i][:10]),
            key=lambda pair: pair[1],
        )[-400:]:
            warm_lines.append(f"ZADD home:{args.auth_id} {ms} {status_id}")
        (out / "valkey.txt").write_text("\n".join(warm_lines) + "\n")

    manifest["counts"] = {
        "account": int(db.run("SELECT count(*) FROM account")),
        "status": int(db.run("SELECT count(*) FROM status")),
        "media_attachment": int(db.run("SELECT count(*) FROM media_attachment")),
        "follow": int(db.run("SELECT count(*) FROM follow")),
        "timeline_entry": int(db.run("SELECT count(*) FROM timeline_entry")),
        "notification": int(db.run("SELECT count(*) FROM notification")),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
