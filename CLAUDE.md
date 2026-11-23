# quetz (ESSS fork)

## Running tests

CI (`.github/workflows/ci.yml`) runs on Linux, in an environment built from
`environment.yml`, with `QUETZ_IS_TEST=1`. Many dependencies are capped there (and in
`setup.cfg`) because newer releases break quetz or its bundled plugins. When CI suddenly
fails across many unrelated tests, look for an unpinned dependency that moved before
suspecting the change under test.

The suite also runs on Windows, without conda, in a uv venv:

```bash
uv venv --python 3.11 .venv
uv pip install --python .venv -e ".[dev]" pyinstrument
QUETZ_IS_TEST=1 .venv/Scripts/python -m pytest quetz/tests
```

- Python 3.11, because quetz still imports `distutils`.
- `pyinstrument` is required but only listed in `environment.yml`.
- Plugin tests need conda packages that are only installed in the Linux environment.

Keep it passing there: build URLs and store paths with `/` (`posixpath`, not
`os.path`), close the files you open, and replace files with `os.replace`. A test that
genuinely cannot run on Windows gets `skipif(sys.platform == "win32")` with the reason.

To check an `environment.yml` change without Linux, solve it for linux-64 with pixi: a
scratch `pixi.toml` with the same dependencies and `platforms = ["linux-64"]`, then
`pixi lock`.

## CI

A full CI run takes only a few minutes, so when watching it, check every 5 minutes
rather than backing off to longer intervals.
