local GNOME, _ = ...

local GSE = GSE
local GCD

local L = GSE.L
local Statics = GSE.Static

--- This function is used to debug a sequence and trace its execution.
function GSE.TraceSequence(button, step, spell, blockPath)
    if GSE.UnsavedOptions.DebugSequenceExecution and not GSE.isEmpty(spell) then
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spell)
        local usableOutput, manaOutput, GCDOutput, CastingOutput
        local spellid = GSE.GetSpellId(spell, Statics.TranslatorMode.ID)
        local foundOutput, FoundInSpellBook
        if GSE.GameMode > 5 then
            if spellid then
                FoundInSpellBook = C_SpellBook.FindSpellBookSlotForSpell(spellid)
                if FoundInSpellBook > 0 then
                    foundOutput =
                        GSEOptions.CommandColour .. "(" .. spellid .. ") Found in Spell Book" .. Statics.StringReset
                else
                    foundOutput = GSEOptions.UNKNOWN .. spell .. " Not Found In Spell Book" .. Statics.StringReset
                end
            else
                foundOutput = GSEOptions.UNKNOWN .. spell .. " Not Found In Spell Book" .. Statics.StringReset
            end
        end
        if isUsable then
            usableOutput = GSEOptions.CommandColour .. "Able To Cast" .. Statics.StringReset
        else
            usableOutput = GSEOptions.UNKNOWN .. "Not Able to Cast" .. Statics.StringReset
        end
        if notEnoughMana then
            manaOutput = GSEOptions.UNKNOWN .. "Resources Not Available" .. Statics.StringReset
        else
            manaOutput = GSEOptions.CommandColour .. "Resources Available" .. Statics.StringReset
        end
        local castingspell = UnitCastingInfo("player")

        if not GSE.isEmpty(castingspell) then
            CastingOutput = GSEOptions.UNKNOWN .. "Casting " .. castingspell .. Statics.StringReset
        else
            CastingOutput = GSEOptions.CommandColour .. "Not actively casting anything else." .. Statics.StringReset
        end
        GCDOutput = GSEOptions.CommandColour .. "GCD Free" .. Statics.StringReset
        if GCD then
            GCDOutput = GSEOptions.UNKNOWN .. "GCD In Cooldown" .. Statics.StringReset
        end

        local fullBlock = blockPath and (GSEOptions.EmphasisColour .. " block:" .. blockPath .. Statics.StringReset) or ""
        local assistedCastOutput = ""
        if C_AssistedCombat and C_AssistedCombat.GetNextCastSpell and C_Spell and C_Spell.GetSpellInfo then
            local nextCast = C_AssistedCombat.GetNextCastSpell()
            local nextInfo = nextCast and C_Spell.GetSpellInfo(nextCast)
            if nextInfo and nextInfo.name then
                assistedCastOutput = nextInfo.name .. ","
            end
        end

        GSE.PrintDebugMessage(
            table.concat(
                {
                    GSEOptions.AuthorColour,
                    button,
                    Statics.StringReset,
                    ",",
                    step,
                    ",",
                    tostring(GetServerTime()),
                    ",",
                    (spell and GSE.GetSpellId(spell, Statics.TranslatorMode.Current) or "nil"),
                    ",",
                    foundOutput and foundOutput .. "," or "",
                    usableOutput,
                    ",",
                    manaOutput,
                    ",",
                    GCDOutput,
                    ",",
                    CastingOutput,
                    assistedCastOutput,
                    fullBlock
                }
            ),
            Statics.SequenceDebug
        )
    end
end

function GSE:UNIT_SPELLCAST_SUCCEEDED(event, unit, action, sped)
    if unit == "player" then
        local GCD_Timer
        local elements = action and GSE.split(action, "-") or {}
        local spellid = elements[6]
        if GSE.GameMode > 1 then
            if C_Spell and C_Spell.GetSpellCooldown then
                if GSE.GameMode > 11 then
                    local cooldownInfo = spellid and C_Spell.GetSpellCooldown(spellid)
                    local potentialGCD = cooldownInfo and cooldownInfo["duration"]
                    if not potentialGCD or issecretvalue(potentialGCD) then
                        GCD_Timer = GSE.GetGCD()
                    else
                        GCD_Timer = potentialGCD
                    end
                else
                    GCD_Timer = GSE.GetGCD()
                end
            else
                ---@diagnostic disable-next-line: deprecated
                local _, gtime = GetSpellCooldown(61304)
                GCD_Timer = gtime
            end
        else
            GCD_Timer = 1.5
        end
        GCD_Timer = tonumber(GCD_Timer) or GSE.GetGCD() or 1.5
        GCD = true

        C_Timer.After(
            GCD_Timer,
            function()
                GCD = nil
                GSE.PrintDebugMessage("GCD OFF")
            end
        )
        GSE.PrintDebugMessage("GCD Delay:" .. " " .. GCD_Timer)
        GSE.CurrentGCD = GCD_Timer

        local foundskill = false
        if GSE.GameMode > 10 then
            local spell

            local found = spellid and C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell(spellid)
            if found then
                local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellid)
                if spellInfo and spellInfo.name then
                    foundskill = true
                    spell = spellInfo.name
                end
            end
            if foundskill then
                if GSE.RecorderActive then
                    GSE.GUIRecordFrame.RecordSequenceBox:SetText(
                        GSE.GUIRecordFrame.RecordSequenceBox:GetText() .. spell .. "\n"
                    )
                end
            end
        else
            local spellInfo = spellid and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellid)
            local spell = spellInfo and spellInfo.name
            local fskilltype = spell and GetSpellBookItemInfo(spell)
            if not GSE.isEmpty(fskilltype) then
                if GSE.RecorderActive then
                    GSE.GUIRecordFrame.RecordSequenceBox:SetText(
                        GSE.GUIRecordFrame.RecordSequenceBox:GetText() .. "/cast " .. spell .. "\n"
                    )
                end
            end
        end
    end
end
GSE:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
