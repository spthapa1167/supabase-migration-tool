#!/usr/bin/env bash
# Shared Docker preflight for edge-function tooling (same behavior as edge_functions_migration.sh).
# Source after lib/logger.sh (requires log_info, log_warning, log_success, log_error).
#
# Env:
#   EDGE_DOCKER_NO_AUTO_START=true   Do not run open/systemctl; fail if Docker is down
#   EDGE_DOCKER_START_WAIT_SEC       Seconds to wait after auto-start (default 120)
#   EDGE_DOCKER_PS_TIMEOUT_SEC       Initial docker ps probe timeout per attempt (default 30)
#   SKIP_DOCKER_CHECK=true           Skip Docker entirely if CLI missing (rare)

_edge_docker_ps_timed() {
    local max="${1:-30}"
    docker ps >/dev/null 2>&1 &
    local dp=$!
    local i=0
    while kill -0 "$dp" 2>/dev/null && [ "$i" -lt "$max" ]; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$dp" 2>/dev/null; then
        log_warning "docker ps exceeded ${max}s — treating as hung."
        kill -9 "$dp" 2>/dev/null || true
        wait "$dp" 2>/dev/null || true
        return 124
    fi
    wait "$dp"
    return $?
}

_edge_docker_ps_with_timeout() {
    _edge_docker_ps_timed "${EDGE_DOCKER_PS_TIMEOUT_SEC:-30}"
}

_edge_force_start_docker() {
    case "$(uname -s)" in
        Darwin)
            log_info "Starting Docker Desktop (open -a Docker)…"
            if open -a Docker 2>/dev/null; then
                return 0
            fi
            log_warning "Could not run \`open -a Docker\`. Install Docker Desktop from https://docker.com/products/docker-desktop"
            return 1
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1; then
                log_info "Trying to start Docker service (systemctl)…"
                if systemctl start docker 2>/dev/null; then
                    return 0
                fi
                if sudo -n systemctl start docker 2>/dev/null; then
                    return 0
                fi
            fi
            log_warning "Could not start Docker via systemctl. Run: sudo systemctl start docker"
            return 1
            ;;
        *)
            log_warning "Start Docker manually for this OS, then re-run this script."
            return 1
            ;;
    esac
}

_edge_wait_for_docker_ready() {
    local total="${EDGE_DOCKER_START_WAIT_SEC:-120}"
    local interval=3
    local elapsed=0
    log_info "Waiting for Docker daemon (up to ${total}s, poll every ${interval}s)…"
    while [ "$elapsed" -lt "$total" ]; do
        if _edge_docker_ps_timed 12; then
            return 0
        fi
        elapsed=$((elapsed + interval))
        log_info "  … Docker not ready yet (${elapsed}s / ${total}s)"
        sleep "$interval"
    done
    return 1
}

# Probe docker ps; if down, try Docker Desktop (macOS) / systemctl (Linux) unless EDGE_DOCKER_NO_AUTO_START=true.
edge_docker_preflight_or_exit() {
    log_info "Preflight: checking Docker (Supabase CLI needs a running daemon for edge functions)…"

    if ! command -v docker >/dev/null 2>&1; then
        if [ "${SKIP_DOCKER_CHECK:-false}" = "true" ]; then
            log_warning "Docker CLI not found — SKIP_DOCKER_CHECK=true, continuing without Docker preflight."
            return 0
        fi
        log_error "Supabase CLI requires Docker for edge function download/deploy. Install Docker or set SKIP_DOCKER_CHECK=true to skip."
        exit 1
    fi

    if [ "${SKIP_DOCKER_CHECK:-false}" = "true" ]; then
        log_warning "SKIP_DOCKER_CHECK=true — skipping Docker daemon preflight."
        return 0
    fi

    log_info "Docker: checking daemon (probe max ${EDGE_DOCKER_PS_TIMEOUT_SEC:-30}s — set EDGE_DOCKER_PS_TIMEOUT_SEC to adjust)…"
    _edge_docker_ps_with_timeout
    local _dock_rc=$?
    if [ "$_dock_rc" -eq 0 ]; then
        log_success "Docker is responding."
        return 0
    fi

    if [ "${EDGE_DOCKER_NO_AUTO_START:-false}" = "true" ]; then
        if [ "$_dock_rc" -eq 124 ]; then
            log_error "Docker probe timed out. Set EDGE_DOCKER_NO_AUTO_START=false to allow auto-start, or start Docker manually."
        else
            log_error "Docker is not running. Start Docker manually or unset EDGE_DOCKER_NO_AUTO_START."
        fi
        exit 1
    fi

    if [ "$_dock_rc" -eq 124 ]; then
        log_warning "Docker probe timed out — will try to start Docker and wait (daemon may be starting)."
    else
        log_warning "Docker is not responding — attempting to start Docker automatically…"
    fi
    _edge_force_start_docker || true
    if ! _edge_wait_for_docker_ready; then
        log_error "Docker still not ready after ${EDGE_DOCKER_START_WAIT_SEC:-120}s."
        log_info "Start Docker Desktop (or \`sudo systemctl start docker\` on Linux), wait until it is fully up, then retry."
        log_info "Increase wait with: EDGE_DOCKER_START_WAIT_SEC=180"
        exit 1
    fi
    log_success "Docker is responding."
}
