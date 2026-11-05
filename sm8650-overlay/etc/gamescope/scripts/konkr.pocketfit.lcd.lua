-- KONKR Pocket FIT internal DSI panel (1080x1920, native 144 Hz).
--
-- Kernel patch 0003 makes the panel list 144/120/90/60 Hz; this profile is
-- a fallback. Without either, gamescope only knows the panel's single
-- 144 Hz mode, so Steam offers 144/n frame limits but no refresh-rate slider
-- and 60 fps content judders on 144 Hz. The panel (panel-ar14-144hz)
-- runs 144/120/90/60 Hz at one pixel clock by stretching the vertical front
-- porch, like the Deck OLED / ROG Ally profiles do.
--
-- The DSI panel has no EDID, so match on the device-tree model instead.

local pocketfit_refresh_rates = { 60, 90, 120, 144 }

local function is_pocketfit()
    local ok, f = pcall(io.open, "/sys/firmware/devicetree/base/model", "r")
    if not ok or not f then return false end
    local model = f:read("*a") or ""
    f:close()
    return model:find("KONKR Pocket FIT", 1, true) ~= nil
end

gamescope.config.known_displays.konkr_pocketfit_lcd = {
    pretty_name = "KONKR Pocket FIT LCD",
    dynamic_refresh_rates = pocketfit_refresh_rates,
    hdr = {
        supported = false,
        force_enabled = false,
        eotf = gamescope.eotf.gamma22,
        max_content_light_level = 500,
        max_frame_average_luminance = 500,
        min_content_light_level = 0.5
    },
    dynamic_modegen = function(base_mode, refresh)
        -- Native mode: 329632 kHz, htotal 1148, vdisplay 1920, VFP 38,
        -- vsync+vback 36 -> vtotal 1994 = 144 Hz. Keep the clock, grow the VFP.
        local htotal = 1148
        local vtotal = math.floor(329632 * 1000 / (htotal * refresh) + 0.5)
        local vfp = vtotal - 1920 - 36
        if vfp < 38 then
            warn("[konkr_pocketfit_lcd] refusing "..refresh.."Hz (vfp "..vfp..")")
            return base_mode
        end
        debug("[konkr_pocketfit_lcd] "..refresh.."Hz: vfp "..vfp.." vtotal "..vtotal)
        local mode = base_mode
        gamescope.modegen.adjust_front_porch(mode, vfp)
        mode.vrefresh = gamescope.modegen.calc_vrefresh(mode)
        return mode
    end,
    matches = function(display)
        -- The DSI panel has no EDID of its own; konkr-panel-edid.service gives
        -- it one (vendor KNK, name "PocketFIT") with the native 144 Hz timing.
        if display.vendor == "KNK" and display.model == "PocketFIT" then
            debug("[konkr_pocketfit_lcd] Matched KNK PocketFIT")
            return 5000
        end
        -- Fallback for an EDID-less panel, in case gamescope ever matches those.
        if (display.vendor or "") == "" and (display.model or "") == "" and is_pocketfit() then
            return 4000
        end
        return -1
    end
}
debug("Registered KONKR Pocket FIT LCD as a known display")
