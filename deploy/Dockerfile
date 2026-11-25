# Production image for Quetz (see deploy/README.md). Build context: the repo root.
#
# The env is the explicit export of quetz02's conda env, so the image runs the same package
# builds as the systemd service did. The source is bind-mounted at /opt/quetz at runtime, so
# switching branches only needs a restart; rebuild when the env file changes.

FROM ubuntu:24.04 AS builder

ARG MICROMAMBA_URL=https://conda.anaconda.org/conda-forge/linux-64/micromamba-2.0.5-0.tar.bz2
ARG MICROMAMBA_SHA256=bfc2e3a414d651af7508c49998a12b5cf3c7029d56c5ef37c9a3248cd7faef78

RUN apt-get update \
    && apt-get install -y --no-install-recommends bzip2 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/micromamba.tar.bz2 "${MICROMAMBA_URL}" \
    && echo "${MICROMAMBA_SHA256}  /tmp/micromamba.tar.bz2" | sha256sum -c - \
    && tar -xjf /tmp/micromamba.tar.bz2 -C /usr/local bin/micromamba \
    && rm /tmp/micromamba.tar.bz2

ENV MAMBA_ROOT_PREFIX=/opt/mamba

COPY deploy/quetz-linux-64.lock /tmp/quetz-linux-64.lock
RUN micromamba create -y -p /env -f /tmp/quetz-linux-64.lock

# py-spy gets its own prefix so its dependencies never touch the Quetz env.
RUN micromamba create -y -p /opt/py-spy -c conda-forge --override-channels \
        "py-spy==0.4.0=h4c5a871_1" \
    && micromamba clean -a -y

# The editable install needs the sources at build time to write Quetz's metadata and entry
# points into /env; the runtime bind mount on /opt/quetz then replaces these files.
COPY setup.py setup.cfg pyproject.toml MANIFEST.in README.md LICENSE /opt/quetz/
COPY quetz /opt/quetz/quetz
RUN /env/bin/pip install --no-deps --no-build-isolation --no-cache-dir -e /opt/quetz


FROM ubuntu:24.04

ARG QUETZ_UID=1776201211
ARG QUETZ_GID=1776200513

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl procps \
    && rm -rf /var/lib/apt/lists/*

# The store has files readable only by their owner, so the container runs as the store
# owner's uid, and with the same primary group the systemd service used for new files.
RUN userdel -r ubuntu 2>/dev/null || true \
    && (getent group "${QUETZ_GID}" >/dev/null || groupadd --gid "${QUETZ_GID}" quetz) \
    && useradd --no-log-init --create-home --home-dir /home/quetz \
        --uid "${QUETZ_UID}" --gid "${QUETZ_GID}" --shell /usr/sbin/nologin quetz

COPY --from=builder /env /env
COPY --from=builder /opt/py-spy /opt/py-spy
COPY --from=builder /opt/quetz /opt/quetz
RUN ln -s /opt/py-spy/bin/py-spy /usr/local/bin/py-spy

ENV PATH=/env/bin:${PATH} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER ${QUETZ_UID}:${QUETZ_GID}
WORKDIR /quetz-deployment
EXPOSE 8000

CMD ["quetz", "start", "/quetz-deployment", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--no-reload", "--log-level", "info"]
