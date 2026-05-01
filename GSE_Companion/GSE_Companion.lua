local GSE = GSE

-- SavedVariables DB for tracking processed/imported entries
GSECompanionBridgeDB = GSECompanionBridgeDB or {}
GSECompanionBridgeDB.processed = GSECompanionBridgeDB.processed or {}
GSECompanionBridgeDB.imported = GSECompanionBridgeDB.imported or {}

local processed = false

-- `processed` tracks queue-entry _ids (one-shot actions — install, delete,
-- reinstall, setPlatformID). Those _ids come fresh from the Companion per
-- action so id-based tracking is appropriate.
local function IsProcessed(id)
    if not id then return false end
    return GSECompanionBridgeDB.processed[id] == true
end

local function MarkProcessed(id)
    if not id then return end
    GSECompanionBridgeDB.processed[id] = true
end

-- `imported` tracks incoming-queue content by stable identity
-- (contentType + name + checksum), NOT by bridge _id. The Companion's
-- sidecar _ids can change across builds / sync cycles (pre-fix builds minted
-- new ids on every write), so _id-based imported tracking was losing its
-- match and re-surfacing items that were already accepted or dismissed.
-- Checksum is included so that genuinely-updated content (same name,
-- new content) re-surfaces instead of being silently skipped.

-- Normalize Qik content type names ("gseVariable", "gseMacro") to the
-- in-mod vocabulary ("variable", "macro", "sequence"). The bridge entries
-- come in with Qik names because that's what the Companion (and Node API)
-- speak; in-mod everything is plain variable/macro/sequence. We translate
-- once at the top of every bridge read so downstream handlers can pattern-
-- match on a single set of strings.
local function normalizeContentType(ct)
    if ct == "gseVariable" then return "variable" end
    if ct == "gseMacro" then return "macro" end
    return ct or "sequence"
end

local function identityKey(item)
    if type(item) ~= "table" then return nil end
    local name = item.name
    if type(name) ~= "string" or name == "" then return nil end
    local ct = normalizeContentType(item.contentType)
    local cs = item.checksum or ""
    return ct .. ":" .. name .. ":" .. cs
end

local function IsImported(item)
    local key = identityKey(item)
    if not key then return false end
    return GSECompanionBridgeDB.imported[key] == true
end

local function MarkImported(item)
    local key = identityKey(item)
    if not key then return end
    GSECompanionBridgeDB.imported[key] = true
end

-- Expose for Import.lua dialog accept and /gse clearincoming so they mark
-- imported by the same identity logic.
GSE = GSE or {}
GSE.CompanionMarkImported = MarkImported
GSE.CompanionIsImported   = IsImported
GSE.CompanionIdentityKey  = identityKey

-- Save-cancels-delete: if the user re-saves content with name X (via the
-- editor, the import dialog accepting an Import for X, or any future Mod
-- path), any pending Companion-bridge delete for the same name+type is
-- resolved silently — the bridge entry's _id is marked processed so the
-- next prune drops it from the sidecar, and the in-memory
-- GSE.PendingBridgeDeletes list (consumed by the import dialog's deletes
-- phase) is cleaned up so the user isn't asked to confirm the delete of
-- something they just saved. The save always wins.
-- Resolve a single pending-delete entry from the import dialog's deletes
-- phase. action is "Delete" or "Ignore". Either way the entry's _id is
-- marked processed (so the next prune drops the bridge sidecar entry)
-- and the entry is removed from GSE.PendingBridgeDeletes (so the dialog
-- doesn't re-render it on the next page open). Only "Delete" enqueues
-- the OOC removal of local content.
function GSE.CompanionConfirmDelete(entryId, contentType, name, classid, action)
    if not entryId or not name then return end
    local ct = (contentType == "gseVariable" and "variable")
            or (contentType == "gseMacro" and "macro")
            or (contentType or "sequence")
    if action == "Delete" then
        if ct == "sequence" then
            local cid = tonumber(classid) or 0
            if cid == 0 and GSESequences then
                for k = 0, 13 do
                    if not GSE.isEmpty(GSESequences[k]) and GSESequences[k][name] then
                        cid = k; break
                    end
                end
            end
            if cid > 0 or (GSESequences and GSESequences[0] and GSESequences[0][name]) then
                GSE.EnqueueOOC({
                    action       = "deletesequence",
                    sequencename = name,
                    classid      = cid,
                })
            end
        elseif ct == "variable" then
            GSE.EnqueueOOC({ action = "deletevariable", variablename = name })
        elseif ct == "macro" then
            GSE.EnqueueOOC({ action = "deletemacro",    macroname    = name })
        end
    end
    MarkProcessed(entryId)
    -- Remove the entry from PendingBridgeDeletes so it doesn't re-render.
    if GSE.PendingBridgeDeletes then
        for idx, d in ipairs(GSE.PendingBridgeDeletes) do
            if d._id == entryId then
                table.remove(GSE.PendingBridgeDeletes, idx)
                break
            end
        end
    end
end

function GSE.CompanionCancelPendingDelete(contentType, name)
    if not name or name == "" then return end
    local ct = (contentType == "gseVariable" and "variable")
            or (contentType == "gseMacro" and "macro")
            or (contentType or "sequence")
    local cancelled = 0
    if GSE.PendingBridgeDeletes then
        local kept = {}
        for _, d in ipairs(GSE.PendingBridgeDeletes) do
            if d.contentType == ct and d.name == name then
                if d._id then MarkProcessed(d._id) end
                cancelled = cancelled + 1
            else
                table.insert(kept, d)
            end
        end
        GSE.PendingBridgeDeletes = kept
    end
    return cancelled
end
-- Test surface — the freshness helpers are defined further down as
-- module-locals; this table gets populated below at the same scope so
-- a busted spec can reach them. Not part of any public contract;
-- callers inside this addon use the local references directly.
GSE.Companion = GSE.Companion or {}

-- Pull the LastUpdated timestamp (YYYYMMDDHHMMSS string) out of a decoded
-- payload. GSE writes this both at the top level and inside MetaData
-- depending on the type and code path; check both. Returns nil when not
-- present (caller treats nil as "unknown timestamp" → don't skip).
local function readLastUpdated(decoded)
    if type(decoded) ~= "table" then return nil end
    if type(decoded.LastUpdated) == "string" or type(decoded.LastUpdated) == "number" then
        return tostring(decoded.LastUpdated)
    end
    if type(decoded.MetaData) == "table" then
        local lu = decoded.MetaData.LastUpdated
        if type(lu) == "string" or type(lu) == "number" then return tostring(lu) end
    end
    return nil
end

-- Pull the local LastUpdated for an item by (contentType, name). Returns
-- nil when the item doesn't exist locally (a fresh install) or has no
-- timestamp recorded. Caller treats nil as "no comparison possible →
-- don't skip".
local function localLastUpdated(contentType, name)
    if not name or name == "" then return nil end
    if contentType == "sequence" or contentType == nil then
        if GSE.Library then
            for cid = 0, 13 do
                local seq = GSE.Library[cid] and GSE.Library[cid][name]
                if type(seq) == "table" then return readLastUpdated(seq) end
            end
        end
    elseif contentType == "gseVariable" or contentType == "variable" then
        if GSEVariables and GSEVariables[name] then
            local ok, decoded = GSE.DecodeMessage(GSEVariables[name])
            if ok then return readLastUpdated(decoded) end
        end
    elseif contentType == "gseMacro" or contentType == "macro" then
        if GSEMacros and type(GSEMacros[name]) == "table" then
            return readLastUpdated(GSEMacros[name])
        end
    end
    return nil
end

-- Decide whether the local copy of (contentType, name) is newer than the
-- incoming bridge entry. Returns true only when both sides have a
-- timestamp AND local > incoming. The "both sides have a timestamp" gate
-- is intentional: if either side is missing one we'd rather risk a
-- redundant import dialog than silently swallow content. Lexical
-- comparison works because GSE.GetTimestamp() emits YYYYMMDDHHMMSS which
-- sorts correctly as strings.
local function isLocalNewer(contentType, name, incomingDecoded)
    local incomingLu = readLastUpdated(incomingDecoded)
    if not incomingLu then return false end
    local localLu = localLastUpdated(contentType, name)
    if not localLu then return false end
    return localLu > incomingLu
end

-- Compare the parts of a decoded variable that determine whether two
-- copies are functionally identical. Both sides have already been
-- decoded; we walk the body fields and ignore everything ephemeral
-- (timestamps, GSE version stamps, server-stamped checksums). When this
-- returns true the import dialog is offering a no-op — the user already
-- has bit-for-bit equivalent local content.
local function localContentMatchesIncoming(contentType, name, incomingDecoded)
    if type(incomingDecoded) ~= "table" or not name or name == "" then return false end
    if contentType == "gseVariable" or contentType == "variable" then
        if not GSEVariables or not GSEVariables[name] then return false end
        local ok, localDecoded = GSE.DecodeMessage(GSEVariables[name])
        if not ok or type(localDecoded) ~= "table" then return false end
        -- Variable identity = funct body. Comments/Author/Dependencies
        -- are derivable or cosmetic; LastUpdated/GSEVersion are
        -- ephemeral. If functs match, the import is a no-op.
        local lf = localDecoded.funct
        local rf = incomingDecoded.funct
        if type(lf) == "string" and type(rf) == "string" and lf == rf then
            return true
        end
        return false
    elseif contentType == "gseMacro" or contentType == "macro" then
        local local_ = GSEMacros and GSEMacros[name]
        if type(local_) ~= "table" then return false end
        local lt = local_.text
        local rt = incomingDecoded.text
        if type(lt) == "string" and type(rt) == "string" and lt == rt then
            return true
        end
        return false
    elseif contentType == "sequence" or contentType == nil then
        -- Sequences carry a much larger body (Versions[]), so walking
        -- structural equality is expensive. Skip the exact-match check
        -- for sequences and let the timestamp/checksum path handle them.
        return false
    end
    return false
end

-- Expose for the busted spec under spec/freshness_spec.lua.
GSE.Companion.readLastUpdated  = readLastUpdated
GSE.Companion.localLastUpdated = localLastUpdated
GSE.Companion.isLocalNewer     = isLocalNewer

-- Wrap a decoded variable or macro object into a synthetic COLLECTION payload
-- so standalone variable/macro pulls flow through the same dialog path as
-- sequences. Sets objectType + name on the decoded object so the dialog's
-- re-encode + re-decode cycle routes to the right OOC handler. Returns the
-- encoded COLLECTION blob or nil if the wrap fails.
local function wrapStandaloneAsCollection(encoded, contentType, name)
    if not encoded or not name or name == "" then return nil end
    local ok, decoded = GSE.DecodeMessage(encoded)
    if not ok or type(decoded) ~= "table" then return nil end
    local payload = {
        Sequences    = {},
        Variables    = {},
        Macros       = {},
        ElementCount = 1,
    }
    if contentType == "variable" or contentType == "gseVariable" then
        decoded.objectType = "VARIABLE"
        if not decoded.name then decoded.name = name end
        payload.Variables[name] = decoded
    elseif contentType == "macro" or contentType == "gseMacro" then
        decoded.objectType = "MACRO"
        if not decoded.name then decoded.name = name end
        payload.Macros[name] = decoded
    else
        return nil
    end
    return GSE.EncodeMessage({ type = "COLLECTION", payload = payload })
end

-- Push a pending install into GSE.IncomingQueue so it shows up in the import
-- dialog (or the auto-accept path). `sequencesField` is a table keyed by name
-- whose values are encoded COLLECTION blobs.
local function enqueueIncoming(item, sequencesField)
    if not GSE.IncomingQueue then GSE.IncomingQueue = {} end
    table.insert(GSE.IncomingQueue, {
        _id         = item._id,
        contentType = item.contentType or "sequence",
        name        = item.name or "",
        author      = item.author or "",
        source      = item.source or "gsecompanion",
        checksum    = item.checksum or "",
        sequences   = sequencesField,
    })
end

local function ProcessBridgeData()
    if processed then return end
    local data = GSECompanionData
    if not data or type(data) ~= "table" then return end

    -- Check if there's anything to process
    local hasQueue = data.queue and #data.queue > 0
    local hasIncoming = data.incomingQueue and #data.incomingQueue > 0
    if not hasQueue and not hasIncoming then return end

    processed = true

    -- Reset the incoming queue so it only reflects what's in the bridge data
    -- file right now — prevents stale entries persisting in SavedVariables.
    GSE.IncomingQueue = {}

    local pendingInstalls = {}

    -- ── Incoming queue (all 4 content types → dialog) ───────────────────────
    -- Variables and macros are wrapped into COLLECTION blobs so the import
    -- dialog handles them identically to sequences. Entries already flagged
    -- in `imported` are skipped so /reload doesn't replay prior imports.
    if hasIncoming then
        for _, item in ipairs(data.incomingQueue) do
            -- Translate Qik content type names to in-mod vocabulary once
            -- here, at the bridge boundary. After this line everything
            -- downstream sees only "sequence" / "variable" / "macro".
            item.contentType = normalizeContentType(item.contentType)
            -- force=true bypasses the IsImported gate AND wipes any prior
            -- marker for this identity. Set by Companion's queue-reinstall
            -- handler so an explicit reinstall always reaches the dialog
            -- even when the user previously dismissed (clearincoming) or
            -- imported the same content.
            if item.force then
                local key = identityKey(item)
                if key then GSECompanionBridgeDB.imported[key] = nil end
            end
            if item.force or not IsImported(item) then
                local ct = item.contentType or "sequence"

                -- Freshness gate (skipped for force/reinstall): if the
                -- local copy of this item is newer than what the bridge
                -- delivered, the local edit supersedes the server's
                -- record. Mark the bridge entry imported so it doesn't
                -- re-cycle, and print a one-liner so the user knows why
                -- the dialog didn't surface this entry. The Companion's
                -- next outgoing sync will push the local copy back up
                -- (deferred while WoW is running, fired on close) and
                -- the two ends will reconverge.
                local supersededByLocal = false
                if not item.force then
                    local incomingDecoded = nil
                    if ct == "sequence" and item.sequences then
                        for _, encodedCol in pairs(item.sequences) do
                            local ok, col = GSE.DecodeMessage(encodedCol)
                            if ok and type(col) == "table"
                               and col.type == "COLLECTION"
                               and type(col.payload) == "table"
                               and type(col.payload.Sequences) == "table" then
                                incomingDecoded = col.payload.Sequences[item.name]
                                if incomingDecoded then break end
                            end
                        end
                    elseif (ct == "variable" or ct == "macro") and item.encoded then
                        local ok, decoded = GSE.DecodeMessage(item.encoded)
                        if ok then incomingDecoded = decoded end
                    end
                    if incomingDecoded then
                        if isLocalNewer(ct, item.name, incomingDecoded) then
                            MarkImported(item)
                            GSE.Print(string.format(
                                "|cff00ccffGSE Companion:|r Local %s |cFFFFFF00%s|r is newer than the website's copy — skipped (your edit will sync back when WoW closes).",
                                ct, tostring(item.name or "?")))
                            supersededByLocal = true
                        elseif localContentMatchesIncoming(ct, item.name, incomingDecoded) then
                            -- Same body bits, just with a different
                            -- checksum the marker table doesn't recognise
                            -- yet (typically because the server stamped
                            -- a fresh ed25519 sig after an auto-collection
                            -- assignment or similar metadata-only touch).
                            -- Importing would be a no-op; mark and skip.
                            MarkImported(item)
                            GSE.Print(string.format(
                                "|cff00ccffGSE Companion:|r Local %s |cFFFFFF00%s|r already matches the website's copy — skipped.",
                                ct, tostring(item.name or "?")))
                            supersededByLocal = true
                        end
                    end
                end

                if not supersededByLocal then
                    local sequencesField = nil
                    if ct == "variable" then
                        if item.encoded and item.name then
                            local wrapped = wrapStandaloneAsCollection(item.encoded, ct, item.name)
                            if wrapped then sequencesField = { [item.name] = wrapped } end
                        end
                    elseif ct == "macro" then
                        if item.encoded and item.name then
                            local wrapped = wrapStandaloneAsCollection(item.encoded, ct, item.name)
                            if wrapped then sequencesField = { [item.name] = wrapped } end
                        end
                    else
                        -- sequence (default): collection blob keyed by name
                        if item.sequences then sequencesField = item.sequences end
                    end

                    if sequencesField then
                        enqueueIncoming(item, sequencesField)
                        table.insert(pendingInstalls, item)
                    end
                end
            end
        end
    end

    -- ── Companion queue entries (install/delete/reinstall/setPlatformID) ────
    if hasQueue then
        local deletes = {}

        for _, entry in ipairs(data.queue) do
            if not IsProcessed(entry._id) then
                -- Same boundary normalization as incomingQueue above.
                entry.contentType = normalizeContentType(entry.contentType)
                local ct = entry.contentType or "sequence"
                if entry.action == "delete" then
                    table.insert(deletes, entry)
                    MarkProcessed(entry._id)
                elseif entry.action == "setPlatformID" then
                    -- The only action that auto-applies (bookkeeping only).
                    -- Branch on contentType so vars and macros stamp into
                    -- the sidecar tables maintained by the GSE addon (see
                    -- GSE.toc SavedVariables list). Without this, only
                    -- sequences round-trip their _id back to SV — vars and
                    -- macros stay orphaned and every sync goes through the
                    -- originKey path, which produces duplicates.
                    local applied = false
                    if ct == "variable" then
                        if entry.name and entry.platformid then
                            GSEVariablePlatformIDs = GSEVariablePlatformIDs or {}
                            GSEVariablePlatformIDs[entry.name] = entry.platformid
                            applied = true
                        end
                    elseif ct == "macro" then
                        if entry.name and entry.platformid then
                            GSEMacroPlatformIDs = GSEMacroPlatformIDs or {}
                            GSEMacroPlatformIDs[entry.name] = entry.platformid
                            applied = true
                        end
                    else
                        -- Sequences: write GSESequences[classid][name] directly
                        -- (the on-disk encoded form), NOT GSE.Library. Library
                        -- is populated lazily — only the player's current class
                        -- + globals load on initial bootstrap, with other
                        -- classes migrated later via OOC. A setPlatformID for
                        -- an unloaded class previously fell through to a
                        -- silent no-op AND still got MarkProcessed, so the
                        -- Companion's reconcile loop re-detected the local
                        -- vs server id mismatch every cycle forever.
                        --
                        -- Strategy: try entry.classid first if it's a hint
                        -- (>0); otherwise scan all classids. On success update
                        -- GSESequences and (if loaded) GSE.Library so the
                        -- editor sees the new id without a /reload.
                        if entry.name and GSESequences then
                            local function tryUpdate(classid)
                                if classid <= 0 then return false end
                                local bucket = GSESequences[classid]
                                if GSE.isEmpty(bucket) then return false end
                                local encoded = bucket[entry.name]
                                if not encoded then return false end
                                local ok, decoded = GSE.DecodeMessage(encoded)
                                if not ok or type(decoded) ~= "table" then return false end
                                local seq
                                if decoded.type == "COLLECTION" and decoded.payload and decoded.payload.Sequences then
                                    seq = decoded.payload.Sequences[entry.name]
                                else
                                    -- Legacy [name, seqData] tuple form.
                                    seq = decoded[2] or decoded
                                end
                                if type(seq) ~= "table" then return false end
                                if not seq.MetaData then seq.MetaData = {} end
                                seq.MetaData.PlatformID = entry.platformid
                                bucket[entry.name] = GSE.EncodeMessage({entry.name, seq})
                                if GSE.Library and GSE.Library[classid] and GSE.Library[classid][entry.name] then
                                    local lib = GSE.Library[classid][entry.name]
                                    if not lib.MetaData then lib.MetaData = {} end
                                    lib.MetaData.PlatformID = entry.platformid
                                end
                                return true
                            end
                            local hint = tonumber(entry.classid) or 0
                            if hint > 0 then applied = tryUpdate(hint) end
                            if not applied then
                                for classid = 0, 13 do
                                    if tryUpdate(classid) then applied = true; break end
                                end
                            end
                        end
                    end
                    -- Only mark processed when the write actually landed. If
                    -- the sequence/var/mac wasn't found locally yet (e.g.
                    -- player hasn't logged into the relevant class), leave
                    -- the entry pending so the next /reload retries instead
                    -- of the Companion re-detecting the same mismatch each
                    -- sync forever.
                    if applied then MarkProcessed(entry._id) end
                elseif entry.action == "install" or entry.action == "reinstall" then
                    -- All installs route through the dialog — sequence,
                    -- variable, and macro alike.
                    local sequencesField = nil
                    if entry.sequences then
                        sequencesField = entry.sequences
                    elseif entry.encoded and entry.name then
                        local wrapped = wrapStandaloneAsCollection(entry.encoded, ct, entry.name)
                        if wrapped then sequencesField = { [entry.name] = wrapped } end
                    end

                    if sequencesField then
                        enqueueIncoming(entry, sequencesField)
                        table.insert(pendingInstalls, entry)
                    end
                    MarkProcessed(entry._id)
                end
            end
        end

        -- Stage delete entries for the import dialog's deletes phase. Each
        -- entry carries the bridge _id so the Mod's "save cancels delete"
        -- hook (and the dialog's OK handler) can MarkProcessed by id when
        -- it resolves the entry. classid is resolved here rather than at
        -- dialog-OK time so we don't depend on GSE.Library being populated
        -- for non-current classes when the user clicks Delete.
        if #deletes > 0 then
            GSE.PendingBridgeDeletes = GSE.PendingBridgeDeletes or {}
            for _, d in ipairs(deletes) do
                local ct = d.contentType or "sequence"
                local resolvedClassId = tonumber(d.classid) or 0
                if ct == "sequence" and resolvedClassId == 0 then
                    for cid = 0, 13 do
                        if not GSE.isEmpty(GSESequences[cid]) and GSESequences[cid][d.name] then
                            resolvedClassId = cid
                            break
                        end
                    end
                end
                table.insert(GSE.PendingBridgeDeletes, {
                    _id         = d._id,
                    contentType = ct,
                    name        = d.name,
                    classid     = resolvedClassId,
                })
            end
        end
    end

    -- ── Surface installs + deletes through the unified dialog ──────────────
    -- One review surface: imports phase first (paginated 20 at a time, with
    -- Import/Replace/Merge/Ignore dropdowns), then a deletes phase (same
    -- pagination, Delete/Ignore dropdowns). Auto-accept covers ONLY installs;
    -- deletes always require explicit user confirmation, every page,
    -- regardless of the auto-accept flag. There is intentionally no
    -- auto-accept-deletes setting — destructive actions stay friction-y by
    -- design.
    local pendingDeleteCount = (GSE.PendingBridgeDeletes and #GSE.PendingBridgeDeletes) or 0
    if #pendingInstalls > 0 or pendingDeleteCount > 0 then
        local autoInstalls = (GSEOptions and GSEOptions.CompanionAutoAccept and #pendingInstalls > 0)
        if autoInstalls then
            C_Timer.After(1, function()
                local imported = 0
                for _, item in ipairs(GSE.IncomingQueue or {}) do
                    for _, encoded in pairs(item.sequences or {}) do
                        local ok, collection = GSE.DecodeMessage(encoded)
                        if ok and collection and collection.type == "COLLECTION" and collection.payload then
                            local p = collection.payload
                            for name, seq in pairs(p.Sequences or {}) do
                                GSE.AddSequenceToCollection(name, seq)
                                imported = imported + 1
                            end
                            for name, varData in pairs(p.Variables or {}) do
                                if type(varData) == "table" then
                                    varData.objectType = nil
                                    GSE.UpdateVariable(varData, name)
                                    imported = imported + 1
                                end
                            end
                            for name, macData in pairs(p.Macros or {}) do
                                if type(macData) == "table" then
                                    macData.objectType = nil
                                    if not macData.name then macData.name = name end
                                    GSE.ImportMacro(macData)
                                    imported = imported + 1
                                end
                            end
                        end
                    end
                    MarkImported(item)
                end
                GSE.IncomingQueue = {}
                GSE.Print(
                    "|cff00ccffGSE Companion:|r Auto-imported " ..
                    imported .. " update(s)."
                )
                -- Imports done silently; if deletes are also pending the
                -- dialog still needs to pop for them (auto-accept is for
                -- installs only).
                if GSE.PendingBridgeDeletes and #GSE.PendingBridgeDeletes > 0 then
                    if GSE.CheckGUI then GSE.CheckGUI() end
                    if GSE.ShowIncomingQueue then
                        C_Timer.After(1, GSE.ShowIncomingQueue)
                    end
                end
            end)
        else
            -- GSE_GUI is load-on-demand; CheckGUI() forces it to load so
            -- ShowIncomingQueue is registered. Without this we'd hit the
            -- "UI is unavailable" branch on first sync after a fresh
            -- launch even when GSE_GUI is installed.
            if GSE.CheckGUI then GSE.CheckGUI() end
            if GSE.ShowIncomingQueue then
                C_Timer.After(1, function()
                    GSE.Print(
                        "|cff00ccffGSE Companion:|r " .. #pendingInstalls ..
                        " import(s) and " .. pendingDeleteCount ..
                        " delete(s) queued — review in the dialog. " ..
                        "Imports show first; deletes follow once imports are done."
                    )
                    GSE.ShowIncomingQueue()
                end)
            else
                GSE.Print(
                    "|cffff6666GSE Companion:|r Incoming items detected but the Incoming Queue UI is unavailable. " ..
                    "Make sure GSE_GUI is loaded, then /reload."
                )
            end
        end
    end

    -- Marker-table cleanup intentionally removed.
    --
    -- Earlier this function pruned markers that weren't currently in
    -- data.queue / data.incomingQueue. That race-discarded markers in
    -- common flows (rapid /reload, Companion offline, large queues capped
    -- to a 20-item visible slice) — leading to "20 stale entries on login"
    -- where the Companion couldn't tell the user had already imported them.
    --
    -- The cost of letting the tables grow is a few KB of SV. The cost of
    -- losing a marker is the user re-seeing the same items every login
    -- with no way to clear them. Trivial to add a /gse companionmarkerprune
    -- slash command later if growth becomes a real concern.
end

-- Trigger after PLAYER_ENTERING_WORLD + out of combat
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if InCombatLockdown() then
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
        else
            C_Timer.After(3, ProcessBridgeData)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        C_Timer.After(1, ProcessBridgeData)
    end
end)
