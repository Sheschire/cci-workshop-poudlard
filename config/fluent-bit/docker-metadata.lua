-- =============================================================================
-- Fluent Bit — Lua filters (CDC §7.4).
--
-- Mounted read-only at /fluent-bit/etc/docker-metadata.lua.
--
-- Two filters:
--   add_docker_metadata  resolve <container-id> → Swarm service / stack / task
--   normalize_level      unify the many spellings of a log level
--
-- Documented in docs/04-composants/fluent-bit.md.
-- =============================================================================

-- Cache: container id → metadata table.
--
-- Without it, every single log line would open and parse a ~30 KB JSON file.
-- At a few thousand lines a second that is the difference between a collector
-- that costs 2 % of a core and one that costs a whole core.
--
-- A container id is immutable and a container's labels never change during its
-- life, so the cache can never go stale for a live container. Only dead ones
-- accumulate, which is what the eviction below handles.
local cache = {}
local cache_size = 0
local CACHE_MAX = 512   -- ~50 containers per node, with generous headroom

-- Where Docker keeps each container's own state file. Bind-mounted read-only.
local CONTAINERS_DIR = "/var/lib/docker/containers/"

-- -----------------------------------------------------------------------------
-- extract_container_id(path)
--
-- Fluent Bit gives us the log file path (Path_Key log_file_path):
--   /var/lib/docker/containers/<64-hex-id>/<64-hex-id>-json.log
-- The id is in the path and nowhere else in the record.
-- -----------------------------------------------------------------------------
local function extract_container_id(path)
    if not path then return nil end
    return string.match(path, "/containers/([0-9a-f]+)/")
end

-- -----------------------------------------------------------------------------
-- read_labels(container_id)
--
-- Parse the container's config.v2.json for the Swarm labels Docker injects:
--   com.docker.swarm.service.name   e.g. "data_galera-1"
--   com.docker.stack.namespace      e.g. "data"
--   com.docker.swarm.task.name      e.g. "data_galera-1.1.xyz"
--
-- Deliberately a targeted string search rather than a real JSON parse: the
-- file is large, Lua has no built-in JSON decoder, and pulling one in would
-- add a dependency to a filter that runs on every log line. The labels have a
-- fixed, quoted shape, so a pattern match is both correct and ~50x cheaper.
-- -----------------------------------------------------------------------------
local function read_labels(container_id)
    local path = CONTAINERS_DIR .. container_id .. "/config.v2.json"
    local file = io.open(path, "r")
    if not file then
        -- Normal case, not an error: the container was removed between the log
        -- line being written and this filter running. The line is still
        -- shipped, just without Swarm metadata.
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content then return nil end

    local meta = {}
    meta.service_name = string.match(content, '"com%.docker%.swarm%.service%.name":"([^"]*)"')
    meta.stack        = string.match(content, '"com%.docker%.stack%.namespace":"([^"]*)"')
    meta.task_name    = string.match(content, '"com%.docker%.swarm%.task%.name":"([^"]*)"')
    meta.node_id      = string.match(content, '"com%.docker%.swarm%.node%.id":"([^"]*)"')
    meta.image        = string.match(content, '"Image":"([^"]*)"')

    -- Plain container name (leading slash stripped), for anything started
    -- outside Swarm — a debugging container, or a backup job run by hand.
    local name = string.match(content, '"Name":"/?([^"]*)"')
    meta.container_name = name

    -- Task slot: "data_galera-1.1.xyz" → "1". Distinguishes replica 1 from
    -- replica 2 of the same service, which matters for glpi-web and grafana.
    if meta.task_name then
        meta.task_slot = string.match(meta.task_name, "%.(%d+)%.")
    end

    return meta
end

-- -----------------------------------------------------------------------------
-- add_docker_metadata — the filter registered in fluent-bit.conf
--
-- Signature imposed by Fluent Bit: (tag, timestamp, record)
-- Return: code, timestamp, record
--   code = 2 → the record was modified, keep it
--   code = 0 → unchanged
--  (code = -1 would drop it; never used here — losing a log line because its
--   metadata could not be resolved would be the wrong trade)
-- -----------------------------------------------------------------------------
function add_docker_metadata(tag, timestamp, record)
    local path = record["log_file_path"] or record["container_path"]
    local cid = extract_container_id(path)

    if not cid then
        return 0, timestamp, record
    end

    record["container_id"] = string.sub(cid, 1, 12)   -- short id, as docker shows it

    local meta = cache[cid]
    if meta == nil then
        meta = read_labels(cid)
        if meta then
            -- Crude but adequate eviction: containers churn slowly here, and a
            -- full flush at the cap is far cheaper than tracking LRU order on
            -- every line.
            if cache_size >= CACHE_MAX then
                cache = {}
                cache_size = 0
            end
            cache[cid] = meta
            cache_size = cache_size + 1
        end
    end

    if meta then
        if meta.service_name   then record["service_name"]   = meta.service_name end
        if meta.stack          then record["stack"]          = meta.stack end
        if meta.task_slot      then record["task_slot"]      = meta.task_slot end
        if meta.node_id        then record["node_id"]        = meta.node_id end
        if meta.container_name then record["container_name"] = meta.container_name end
        if meta.image          then record["image"]          = meta.image end
    end

    -- The full path is noise once the id is extracted, and it would be indexed.
    record["log_file_path"] = nil
    record["container_path"] = nil

    return 2, timestamp, record
end

-- -----------------------------------------------------------------------------
-- normalize_level
--
-- Every service spells its severity differently: Traefik and Elasticsearch use
-- "level", MariaDB writes "[ERROR]" inline, Cassandra writes "ERROR" at the
-- start of the line. A dashboard panel counting errors per service needs ONE
-- field with ONE vocabulary.
--
-- Output vocabulary: debug | info | warn | error | fatal
-- -----------------------------------------------------------------------------
local LEVEL_MAP = {
    trace = "debug", debug = "debug",
    info = "info", information = "info", notice = "info", note = "info",
    warn = "warn", warning = "warn",
    err = "error", error = "error", severe = "error",
    crit = "fatal", critical = "fatal", fatal = "fatal", emerg = "fatal",
    alert = "fatal", panic = "fatal",
}

function normalize_level(tag, timestamp, record)
    -- 1. An explicit field, if the service emitted structured JSON.
    local raw = record["level"] or record["log_level"] or record["severity"]

    -- 2. Otherwise, look for a bracketed level at the start of the message.
    --    Bounded to the first 120 characters so a long stack trace is not
    --    scanned line by line.
    if not raw then
        local msg = record["message"] or record["log"]
        if type(msg) == "string" then
            local head = string.sub(msg, 1, 120)
            raw = string.match(head, "%[(%a+)%]")            -- [ERROR]
               or string.match(head, "^(%u%u+)%s")           -- ERROR ...
               or string.match(head, "level=(%a+)")          -- level=error
        end
    end

    if type(raw) == "string" then
        local normalized = LEVEL_MAP[string.lower(raw)]
        if normalized then
            record["log_level"] = normalized
            return 2, timestamp, record
        end
    end

    -- Unknown severity is recorded as `info` rather than left absent: a missing
    -- field would silently disappear from every terms aggregation, making the
    -- "errors per service" panel under-report instead of showing a gap.
    record["log_level"] = record["log_level"] or "info"
    return 2, timestamp, record
end
