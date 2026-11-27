# Production deployment (packages.esss.com)

Quetz and its Postgres run on **quetz02** (`10.0.0.189`) with Docker Compose, from the clone
`/opt/quetz` (owned by fred), used only by this stack. `/home/users/fred/quetz` is the old systemd
service's checkout, kept for the rollback until it's deleted (cutover step 10). The repo-root
`docker-compose.yml` is upstream's dev stack; don't use it.

| File | What it is |
| --- | --- |
| `docker-compose.yml` | Project `quetz-prod`: `postgres` (18.6, `max_connections=300`) and `quetz` |
| `Dockerfile` | Ubuntu 24.04 + the conda env from `quetz-linux-64.lock` + py-spy; the source is bind-mounted |
| `quetz-linux-64.lock` | The exact env the systemd service ran (exported 2026-11-24) |
| `.env.example` | Template for `.env`, the only untracked file: host paths, uid/gid, DB password |
| `watchdog/` | Host timers: restart on unhealthy with evidence, deep check, stats history |
| `update-lock.sh` | Re-solves `environment.yml` into a new `quetz-linux-64.lock` |

All commands below run on quetz02 as a sudoer, from `/opt/quetz/deploy`, with
`sudo` in front of `docker`.

## Health, restart and evidence

- **Liveness:** Docker curls `/health/live` every 30 s. It's a sync endpoint, so it fails when the
  AnyIO threadpool is exhausted, which is how Quetz froze in Nov 2026. After 3 failures (~2 min)
  the container is `unhealthy`.
- **Docker never restarts an `unhealthy` container** by itself. `quetz-heal.timer` does it every
  minute: when `quetz-prod-quetz-1` is unhealthy it saves `py-spy dump`s of every Python process, the
  last 2000 log lines and the recent stats to `/var/log/quetz/incidents/<UTC time>/`, runs
  `docker restart -t 10`, and logs what it did to the journal.
- **Back-off:** after 3 incidents within an hour it stops restarting and logs `backing off` on every
  run instead; a person has to look.
- **Crashes and OOM:** `restart: unless-stopped` brings the container back. `mem_limit: 5g` keeps a
  runaway Quetz inside its own cgroup (on 2026-11-22 it reached 5.56 GB and the kernel OOM killer
  hit the host).
- **History:** every heal run (once a minute) appends CPU, memory and PIDs (≈ threads) of both
  containers to `/var/log/quetz/stats.csv`.
- **Deep check:** `quetz-deepcheck.timer` HEADs `noarch/repodata.json` of `conda-forge`,
  `anaconda-main` and `esss` every 5 min and logs `FAILED <channel>` (the unit run fails) when Quetz
  fails while the upstream answers. It never restarts anything.
- **No alerts yet:** nothing is posted anywhere (follow-up below), so check the journal and
  `/var/log/quetz/` when CI reports problems.

```bash
sudo docker compose ps                                  # STATUS shows (healthy)/(unhealthy)
sudo docker inspect -f '{{json .State.Health}}' quetz-prod-quetz-1 | python3 -m json.tool
sudo docker compose logs --tail 200 -f quetz
ls -lt /var/log/quetz/incidents/ | head
sudo journalctl -u 'quetz-watchdog@*' --since -1h | grep -v 'Deactivated\|Finished\|Starting' | tail -50
tail -20 /var/log/quetz/deepcheck.csv /var/log/quetz/stats.csv
# stack dump of the server and the job supervisor, without restarting anything:
sudo docker exec -u 0 quetz-prod-quetz-1 sh -c 'for p in $(pgrep -f python); do py-spy dump --pid $p; done'
```

## Day to day

```bash
sudo docker compose up -d                # start or apply compose changes
sudo docker compose restart quetz        # after a code change (git checkout/pull)
sudo docker compose up -d --build quetz  # after a Dockerfile or lock change
sudo docker compose build --pull quetz && sudo docker compose up -d quetz  # Ubuntu security updates
sudo docker compose down                 # stop both; NEVER `down -v`
```

**Testing a branch.** The checkout is the code the container runs:

```bash
sudo -u fred git -C /opt/quetz fetch origin
sudo -u fred git -C /opt/quetz checkout --detach origin/<branch>
sudo docker compose restart quetz
# back:
sudo -u fred git -C /opt/quetz checkout main && sudo -u fred git -C /opt/quetz pull
sudo docker compose restart quetz
```

Only check out branches that contain `deploy/` (created from `main` after it was merged).
Otherwise the compose files disappear from disk: the containers keep running and the watchdog keeps
working, but `docker compose` commands fail until you switch back. `.env` is untracked and
survives every checkout.

**Database:**

```bash
sudo docker compose exec postgres psql -U postgres -d quetz
(umask 077; sudo docker compose exec -T postgres pg_dump -U postgres -d quetz -Fc > ~/quetz-db-$(date +%F).dump)
# restore into an empty `quetz` DB (with quetz stopped):
sudo docker compose exec -T postgres pg_restore -U postgres -d quetz --no-owner < quetz-db-<date>.dump
```

Postgres no longer publishes 5432; Quetz reaches it on the compose network.

## Configuration

- Quetz reads the deployment's own `config.toml` (`/home/users/fred/quetz_server/config.toml`,
  the same file the systemd service used), so GitHub, session, `[users]` and logging settings stay
  where they were.
- Only the database comes from the compose file: `QUETZ_SQLALCHEMY_DATABASE_URL` points at the
  `postgres` service. **Quetz replaces a whole config section with the env one**, so the file's
  `[sqlalchemy]` settings are ignored and the pool size (90) is repeated in the compose file.
- `.env` (`chmod 600`, owned by root) holds the host paths, the store owner's uid/gid,
  `FORWARDED_ALLOW_IPS` (`*` as under systemd: the TLS proxy connects from several addresses) and
  `POSTGRES_PASSWORD`. That's used both for the DB URL and by `initdb` on an empty data dir; to change
  the password of the existing cluster, `ALTER USER postgres PASSWORD '...'` and update `.env`.
- `[users]` roles are applied only by `quetz add-user-roles` (or `quetz create`), not at start,
  and only to users without a role yet. To apply the lists:
  `sudo docker compose exec quetz quetz add-user-roles /quetz-deployment`. To change an existing
  user's role, update `users.role` in the database (`owner`, `maintainer` or `member`).
- fred's crontab still deletes the cached `.zst` repodata under `channels/` every night; the
  container writes there as fred's uid, so it keeps working unchanged.
- Logs follow `config.toml` `[logging]` as before (level and `quetz.log` in the deployment dir),
  and also go to `docker logs` (json-file, 10 × 50 MB).

**Recommendation for the proxy in front** (10.0.1.253/.254): fail fast instead of holding CI clients
for 10 min per request, e.g. `proxy_connect_timeout 10s; proxy_read_timeout 120s;` (nginx names).

## Installing the host timers

`watchdog/quetz-watchdog.sh` has two modes, `heal` and `deepcheck`, run by the template service
`quetz-watchdog@.service` from two timers (`quetz-heal.timer` every minute, `quetz-deepcheck.timer`
every 5 min), so a slow deep check never delays a restart.

```bash
sudo install -m 755 watchdog/quetz-watchdog.sh /usr/local/sbin/quetz-watchdog
sudo install -m 644 watchdog/quetz-watchdog@.service watchdog/quetz-{heal,deepcheck}.timer \
    /etc/systemd/system/
sudo install -m 644 watchdog/quetz-watchdog.logrotate /etc/logrotate.d/quetz-watchdog
# read-only API key for the deep check; sudoedit keeps it out of shell history
sudo install -d -m 700 /etc/quetz && sudo install -m 600 /dev/null /etc/quetz/deepcheck.env
sudoedit /etc/quetz/deepcheck.env      # one line: QUETZ_DEEPCHECK_API_KEY=<key>
sudo systemctl daemon-reload
sudo systemctl enable --now quetz-heal.timer quetz-deepcheck.timer
```

The script is copied out of the checkout on purpose: a branch without `deploy/` must not break
recovery. Re-run the first `install` line after changing it.

## Updating the dependencies

The image installs exactly `quetz-linux-64.lock`, so a rebuild never changes package
versions by itself. To upgrade on purpose:

On a workstation with Docker, in `deploy/`:

```bash
./update-lock.sh             # ~1 min: solves environment.yml, rewrites the lock, lists the changes
git diff quetz-linux-64.lock
docker compose build quetz   # then test it before the PR
```

Do it in its own PR and test it before deploying: a fresh solve moves many packages at once (on
2026-11-25 it would have taken anyio 3.6 → 4.16, starlette 0.37 → 0.52, uvicorn 0.29 → 0.54,
sqlalchemy 2.0 → 2.1), and anyio runs the threadpool behind the November freezes.

## Follow-ups

- **Alerts:** post the watchdog's restarts and back-offs and the deep check's failures to
  #devops > Quetz (e.g. a Zulip bot called from both scripts). Until then, look at the journal and
  `/var/log/quetz/`.

## Cutover from systemd (2026-11-30)

Outside 05:30–07:30 UTC (nightly CI at 06:08, apt upgrades at 06:00), with Fred online and a notice
in #devops.

**Dry run (2026-11-27).** Clone, `.env` and build only; the systemd Quetz keeps serving from
`/home/users/fred/quetz`, which none of this touches:

```bash
sudo install -d -o fred -g "$(id -g fred)" -m 755 /opt/quetz
sudo -u fred git clone "$(sudo -u fred git -C /home/users/fred/quetz remote get-url origin)" /opt/quetz
sudo -u fred git -C /opt/quetz checkout --detach origin/fb-EDEN-2931-compose   # skip once merged
cd /opt/quetz/deploy
sudo install -m 600 -o root -g root .env.example .env
sudoedit .env     # POSTGRES_PASSWORD: a new one, from `openssl rand -hex 24`
sudo docker compose build
```

Compose refuses even `build` without `POSTGRES_PASSWORD`. That new password is set on the cluster
at step 4.

1. `pg_dump` (see above) from the old stack:
   `sudo docker exec postgres-postgres-1 pg_dump -U postgres -d quetz -Fc`. The DB holds every
   user, role, channel and API key; copy the dump off the VM too.
2. Check that `/opt/quetz/deploy/.env` is there (from the dry run). If `main` moved since, pull it
   in `/opt/quetz`.
3. `sudo systemctl disable --now quetz`.
4. Set `.env`'s `POSTGRES_PASSWORD` on the old container (prompts, so it stays out of shell history):
   `sudo docker exec -it postgres-postgres-1 psql -U postgres -c '\password postgres'`.
5. `cd /home/users/fred/postgres && sudo docker compose down` (no `-v`).
   **Check `sudo docker ps` shows no Postgres before going on:** two Postgres containers on the
   same data dir corrupt it.
   **Fred takes the VM snapshot now:** with Quetz and Postgres both stopped, the DB files on disk are
   consistent.
6. `cd /opt/quetz/deploy && sudo docker compose up -d --build`, then
   `sudo docker compose ps` until both are `healthy`, and
   `sudo docker compose exec postgres psql -U postgres -d quetz -c 'SHOW max_connections'` → 300.
7. Check from a workstation (each should print 200), then watch the next CI run or re-run a job:
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://packages.esss.com/health/live
   curl -sS -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $QUETZ_API_KEY" https://packages.esss.com/get/esss/noarch/repodata.json
   curl -sS -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $QUETZ_API_KEY" https://packages.esss.com/get/conda-forge/linux-64/_libgcc_mutex-0.1-conda_forge.tar.bz2
   ```
   Anything else → rollback.
8. Install the host timers (above) and enable sysstat
    (`ENABLED="true"` in `/etc/default/sysstat`, `sudo systemctl restart sysstat`).
9. Make lincrosenbach a server maintainer (they're `member` today, so `add-user-roles` skips them):
    `sudo docker compose exec postgres psql -U postgres -d quetz -c "UPDATE users SET role = 'maintainer' WHERE username = 'lincrosenbach'"`.
10. After about a week without a rollback, delete what only the systemd service used:
    `/home/users/fred/quetz`, `/home/users/fred/start_quetz.sh`, the conda env
    `/home/users/fred/mambaforge/envs/quetz`, `/etc/systemd/system/quetz.service` and the old
    `/home/users/fred/postgres/docker-compose.yml` (not its `data/`: that's the live data dir).

**Rollback:**

```bash
cd /opt/quetz/deploy && sudo docker compose down
cd /home/users/fred/postgres && sudo docker compose up -d
# config.toml was never changed, but its database_url still has the old password:
# put the rotated one there first
sudo systemctl enable --now quetz
```

The old `/home/users/fred/postgres/docker-compose.yml` uses the same data dir, so nothing is
copied either way. The systemd service runs from `/home/users/fred/quetz`, which the cutover never
touched. If the rollback itself fails, restore the step 5 snapshot; it loses whatever was uploaded
after it.
