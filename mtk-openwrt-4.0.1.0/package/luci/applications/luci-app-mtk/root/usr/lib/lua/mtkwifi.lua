#!/usr/bin/env lua

--[[
 * A lua library to manipulate mtk's wifi driver. used in luci-app-mtk.
 *
 * Copyright (C) 2016 Hua Shao <nossiac@163.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License version 2.1
 * as published by the Free Software Foundation
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
]]

local mtkwifi = {}

function debug_write(...)
    -- luci.http.write(...)
    local syslog_msg = "";
    local ff = io.open("/tmp/mtkwifi", "a")
    local nargs = select('#',...)
    for n=1, nargs do
      local v = select(n,...)
      if (type(v) == "string" or type(v) == "number") then
        ff:write(v.." ")
        syslog_msg = syslog_msg..v.." ";
      elseif (type(v) == "boolean") then
        if v then
          ff:write("true ")
          syslog_msg = syslog_msg.."true ";
        else
          ff:write("false ")
          syslog_msg = syslog_msg.."false ";
        end
      elseif (type(v) == "nil") then
        ff:write("nil ")
        syslog_msg = syslog_msg.."nil ";
      else
        ff:write("<Non-printable data type = "..type(v).."> ")
        syslog_msg = syslog_msg.."<Non-printable data type = "..type(v).."> ";
      end
    end
    ff:write("\n")
    ff:close()
    nixio.syslog("debug", syslog_msg)
end

function string:split(sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

function mtkwifi.__trim(s)
  if s then return (s:gsub("^%s*(.-)%s*$", "%1")) end
end

function mtkwifi.__handleSpecialChars(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"", "\\\"")
    return s
end

function mtkwifi.__spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    --[[
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
        -- table.sort(keys, order)
    else
        table.sort(keys)
    end
    ]]
    table.sort(keys, order)
    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

function mtkwifi.__lines(str)
    local t = {}
    local function helper(line) table.insert(t, line) return "" end
    helper((str:gsub("(.-)\r?\n", helper)))
    return t
end

function mtkwifi.__get_l1dat()
    if not pcall(require, "l1dat_parser") then
        return
    end

    local parser = require("l1dat_parser")
    local l1dat = parser.load_l1_profile(parser.L1_DAT_PATH)

    return l1dat, parser
end

function mtkwifi.sleep(s)
    local ntime = os.clock() + s
    repeat until os.clock() > ntime
end

function mtkwifi.deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[mtkwifi.deepcopy(orig_key)] = mtkwifi.deepcopy(orig_value)
        end
        setmetatable(copy, mtkwifi.deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

function mtkwifi.read_pipe(pipe)
    local fp = io.popen(pipe)
    local txt =  fp:read("*a")
    fp:close()
    return txt
end

function mtkwifi.load_profile(path, raw)
    local cfgs = {}
    local content

    if path then
    local fd = io.open(path, "r")
    if not fd then return end
        content = fd:read("*all")
        fd:close()
    elseif raw then
        content = raw
    else
        return
    end

    -- convert profile into lua table
    for _,line in ipairs(mtkwifi.__lines(content)) do
        -- Trim only leading space characters
        line = line:gsub("^%s*(.-)$","%1")
        if string.byte(line) ~= string.byte("#") then
            local i = string.find(line, "=")
            if i then
                local k,v
                k = mtkwifi.__trim(string.sub(line, 1, i-1))
                v = string.sub(line, i+1)
                if cfgs[k] then
                    nixio.syslog("warning", "skip repeated key"..line)
                end
                if k == k:match("^SSID%d-$") or k == "ApCliSsid" then
                    cfgs[k] = v or ""
                else
                    cfgs[k] = mtkwifi.__trim(v) or ""
                end
            else
                nixio.syslog("warning", "skip line without '=' "..line)
            end
        else
            nixio.syslog("warning", "skip comment line "..line)
        end
    end
    return cfgs
end


function mtkwifi.save_profile(cfgs, path)

    if not cfgs then
        debug_write("configuration was empty, nothing saved")
        return
    end

    -- Keep a backup of last profile settings
    os.execute("cp -f "..path.." "..mtkwifi.__profile_previous_settings_path(path))

    -- Keep another backup of last profile settings which would be used by
    -- function __mtkwifi_reload() in controller/mtkwifi.lua file only if it does not exist.
    if not mtkwifi.exists(mtkwifi.__profile_applied_settings_path(path)) then
        os.execute("cp -f "..path.." "..mtkwifi.__profile_applied_settings_path(path))
    end

    local fd = io.open(path, "w")
    table.sort(cfgs, function(a,b) return a<b end)
    if not fd then return end
    fd:write("# Generated by mtkwifi.lua\n")
    fd:write("Default\n")
    for k,v in mtkwifi.__spairs(cfgs, function(a,b) return string.upper(a) < string.upper(b) end) do
        fd:write(k.."="..v.."\n")
    end
    fd:close()

    if pcall(require, "mtknvram") then
        local nvram = require("mtknvram")
        local l1dat, l1 = mtkwifi.__get_l1dat()
        local zone = l1 and l1.l1_path_to_zone(path)

        if not l1dat then
            debug_write("save_profile: no l1dat", path)
            nvram.nvram_save_profile(path)
        else
            if zone then
                debug_write("save_profile:", path, zone)
                nvram.nvram_save_profile(path, zone)
            else
                debug_write("save_profile:", path)
                nvram.nvram_save_profile(path)
            end
        end
    end
end

function mtkwifi.split_profile(path, path_2g, path_5g)
    assert(path)
    assert(path_2g)
    assert(path_5g)
    local cfgs = mtkwifi.load_profile(path)
    local dirty = {
        "Channel",
        "WirelessMode",
        "TxRate",
        "WmmCapable",
        "NoForwarding",
        "HideSSID",
        "IEEE8021X",
        "PreAuth",
        "AuthMode",
        "EncrypType",
        "RekeyMethod",
        "RekeyInterval",
        "PMKCachePeriod",
        "DefaultKeyId",
        "Key{n}Type",
        "HT_EXTCHA",
        "RADIUS_Server",
        "RADIUS_Port",
    }
    local cfg5g = mtkwifi.deepcopy(cfgs)
    for _,v in ipairs(dirty) do
        cfg5g[v] = mtkwifi.token_get(cfgs[v], 1, 0)
        assert(cfg5g[v])
    end
    mtkwifi.save_profile(cfg5g, path_5g)

    local cfg2g = mtkwifi.deepcopy(cfgs)
    for _,v in ipairs(dirty) do
        cfg2g[v] = mtkwifi.token_get(cfgs[v], 1, 0)
        assert(cfg2g[v])
    end
    mtkwifi.save_profile(cfg2g, path_2g)
end

function mtkwifi.merge_profile(path, path_2g, path_5g)
    local cfg2g = mtkwifi.load_profile(path_2g)
    local cfg5g = mtkwifi.load_profile(path_5g)
    local dirty = {
        "Channel",
        "WirelessMode",
        "TxRate",
        "WmmCapable",
        "NoForwarding",
        "HideSSID",
        "IEEE8021X",
        "PreAuth",
        "AuthMode",
        "EncrypType",
        "RekeyMethod",
        "RekeyInterval",
        "PMKCachePeriod",
        "DefaultKeyId",
        "Key{n}Type",
        "HT_EXTCHA",
        "RADIUS_Server",
        "RADIUS_Port",
    }
    local cfgs = mtkwifi.deepcopy(cfg2g)
    for _,v in dirty do
        -- TODO
    end
    mtkwifi.save_profile(cfgs, path)
end

function mtkwifi.__profile_previous_settings_path(profile)
    assert(type(profile) == "string")
    local bak = "/tmp/mtk/wifi/"..string.match(profile, "([^/]+)\.dat")..".last"
    os.execute("mkdir -p /tmp/mtk/wifi")
    return bak
end

function mtkwifi.__profile_applied_settings_path(profile)
    assert(type(profile) == "string")
    local bak = "/tmp/mtk/wifi/"..string.match(profile, "([^/]+)\.dat")..".applied"
    os.execute("mkdir -p /tmp/mtk/wifi")
    return bak
end

-- if path2 is not given, use backup of path1.
function mtkwifi.diff_profile(path1, path2)
    assert(path1)
    if not path2 then
        path2 = mtkwifi.__profile_applied_settings_path(path1)
        if not mtkwifi.exists(path2) then
            return {}
        end
    end
    assert(path2)

    local diff = {}
    local cfg1 = mtkwifi.load_profile(path1) or {}
    local cfg2 = mtkwifi.load_profile(path2) or {}

    for k,v in pairs(cfg1) do
        if cfg2[k] ~= cfg1[k] then
            diff[k] = {cfg1[k] or "", cfg2[k] or ""}
        end
    end

    for k,v in pairs(cfg2) do
        if cfg2[k] ~= cfg1[k] then
            diff[k] = {cfg1[k] or "", cfg2[k] or ""}
        end
    end

    return diff
end

-- Mode 12 and 13 are only available for STAs.
local WirelessModeList = {
    [0] = "B/G mixed",
    [1] = "B only",
    [2] = "A only",
    -- [3] = "A/B/G mixed",
    [4] = "G only",
    -- [5] = "A/B/G/GN/AN mixed",
    [6] = "N in 2.4G only",
    [7] = "G/GN", -- i.e., no CCK mode
    [8] = "A/N in 5 band",
    [9] = "B/G/GN mode",
    -- [10] = "A/AN/G/GN mode", --not support B mode
    [11] = "only N in 5G band",
    -- [12] = "B/G/GN/A/AN/AC mixed",
    -- [13] = "G/GN/A/AN/AC mixed", -- no B mode
    [14] = "A/AC/AN mixed",
    [15] = "AC/AN mixed", --but no A mode
}

local DevicePropertyMap = {
    -- 2.4G
    {device="MT7622", band={"0", "1", "4", "9"}},
    {device="MT7628", band={"0", "1", "4", "6", "7", "9"}},
    {device="MT7603", band={"0", "1", "4", "6", "7", "9"}},
    -- 5G
    {device="MT7612", band={"2", "8", "11", "14", "15"}},
    {device="MT7662", band={"2", "8", "11", "14", "15"}},
    -- Mix
    {device="MT7615", band={"0", "1", "4", "9", "2", "8", "14", "15"}},
    {device="MT7663", band={"0", "1", "4", "9", "2", "8", "14", "15"}, maxTxStream=2, maxRxStream=2, invalidChBwList={60,160,161}},
    {device="MT7613", band={"0", "1", "4", "9", "2", "8", "14", "15"}, maxTxStream=2, maxRxStream=2, invalidChBwList={60,160,161}}
}

mtkwifi.CountryRegionList_5G_All = {
    {region=0, text="0: Ch36~64, Ch149~165"},
    {region=1, text="1: Ch36~64, Ch100~140"},
    {region=2, text="2: Ch36~64"},
    {region=3, text="3: Ch52~64, Ch149~161"},
    {region=4, text="4: Ch149~165"},
    {region=5, text="5: Ch149~161"},
    {region=6, text="6: Ch36~48"},
    {region=7, text="7: Ch36~64, Ch100~140, Ch149~165"},
    {region=8, text="8: Ch52~64"},
    {region=9, text="9: Ch36~64, Ch100~116, Ch132~140, Ch149~165"},
    {region=10, text="10: Ch36~48, Ch149~165"},
    {region=11, text="11: Ch36~64, Ch100~120, Ch149~161"},
    {region=12, text="12: Ch36~64, Ch100~144"},
    {region=13, text="13: Ch36~64, Ch100~144, Ch149~165"},
    {region=14, text="14: Ch36~64, Ch100~116, Ch132~144, Ch149~165"},
    {region=15, text="15: Ch149~173"},
    {region=16, text="16: Ch52~64, Ch149~165"},
    {region=17, text="17: Ch36~48, Ch149~161"},
    {region=18, text="18: Ch36~64, Ch100~116, Ch132~140"},
    {region=19, text="19: Ch56~64, Ch100~140, Ch149~161"},
    {region=20, text="20: Ch36~64, Ch100~124, Ch149~161"},
    {region=21, text="21: Ch36~64, Ch100~140, Ch149~161"},
    {region=22, text="22: Ch100~140"},
    {region=30, text="30: Ch36~48, Ch52~64, Ch100~140, Ch149~165"},
    {region=31, text="31: Ch52~64, Ch100~140, Ch149~165"},
    {region=32, text="32: Ch36~48, Ch52~64, Ch100~140, Ch149~161"},
    {region=33, text="33: Ch36~48, Ch52~64, Ch100~140"},
    {region=34, text="34: Ch36~48, Ch52~64, Ch149~165"},
    {region=35, text="35: Ch36~48, Ch52~64"},
    {region=36, text="36: Ch36~48, Ch100~140, Ch149~165"},
    {region=37, text="37: Ch36~48, Ch52~64, Ch149~165, Ch173"},
}

mtkwifi.CountryRegionList_2G_All = {
    {region=0, text="0: Ch1~11"},
    {region=1, text="1: Ch1~13"},
    {region=2, text="2: Ch10~11"},
    {region=3, text="3: Ch10~13"},
    {region=4, text="4: Ch14"},
    {region=5, text="5: Ch1~14"},
    {region=6, text="6: Ch3~9"},
    {region=7, text="7: Ch5~13"},
    {region=31, text="31: Ch1~11, Ch12~14"},
    {region=32, text="32: Ch1~11, Ch12~13"},
    {region=33, text="33: Ch1~14"},
}

mtkwifi.ChannelList_5G_All = {
    {channel=0,  text="Channel 0 (Auto )", region={}},
    {channel= 36, text="Channel  36 (5.180 GHz)", region={[0]=1, [1]=1, [2]=1, [6]=1, [7]=1, [9]=1, [10]=1, [11]=1, [12]=1, [13]=1, [14]=1, [17]=1, [18]=1, [20]=1, [21]=1, [30]=1, [32]=1, [33]=1, [34]=1, [35]=1, [36]=1, [37]=1}},
    {channel= 40, text="Channel  40 (5.200 GHz)", region={[0]=1, [1]=1, [2]=1, [6]=1, [7]=1, [9]=1, [10]=1, [11]=1, [12]=1, [13]=1, [14]=1, [17]=1, [18]=1, [20]=1, [21]=1, [30]=1, [32]=1, [33]=1, [34]=1, [35]=1, [36]=1, [37]=1}},
    {channel= 44, text="Channel  44 (5.220 GHz)", region={[0]=1, [1]=1, [2]=1, [6]=1, [7]=1, [9]=1, [10]=1, [11]=1, [12]=1, [13]=1, [14]=1, [17]=1, [18]=1, [20]=1, [21]=1, [30]=1, [32]=1, [33]=1, [34]=1, [35]=1, [36]=1, [37]=1}},
    {channel= 48, text="Channel  48 (5.240 GHz)", region={[0]=1, [1]=1, [2]=1, [6]=1, [7]=1, [9]=1, [10]=1, [11]=1, [12]=1, [13]=1, [14]=1, [17]=1, [18]=1, [20]=1, [21]=1, [30]=1, [32]=1, [33]=1, [34]=1, [35]=1, [36]=1, [37]=1}},
    {channel= 52, text="Channel  52 (5.260 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [7]=1, [8]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [16]=1, [18]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [33]=1, [34]=1, [35]=1, [37]=1}},
    {channel= 56, text="Channel  56 (5.280 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [7]=1, [8]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [16]=1, [18]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [33]=1, [34]=1, [35]=1, [37]=1}},
    {channel= 60, text="Channel  60 (5.300 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [7]=1, [8]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [16]=1, [18]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [33]=1, [34]=1, [35]=1, [37]=1}},
    {channel= 64, text="Channel  64 (5.320 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [7]=1, [8]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [16]=1, [18]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [33]=1, [34]=1, [35]=1, [37]=1}},
    {channel=100, text="Channel 100 (5.500 GHz)", region={[1]=1, [7]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=104, text="Channel 104 (5.520 GHz)", region={[1]=1, [7]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=108, text="Channel 108 (5.540 GHz)", region={[1]=1, [7]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=112, text="Channel 112 (5.560 GHz)", region={[1]=1, [7]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=116, text="Channel 116 (5.580 GHz)", region={[1]=1, [7]=1, [9]=1, [11]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=120, text="Channel 120 (5.600 GHz)", region={[1]=1, [7]=1, [11]=1, [12]=1, [13]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=124, text="Channel 124 (5.620 GHz)", region={[1]=1, [7]=1, [12]=1, [13]=1, [19]=1, [20]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=128, text="Channel 128 (5.640 GHz)", region={[1]=1, [7]=1, [12]=1, [13]=1, [19]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=132, text="Channel 132 (5.660 GHz)", region={[1]=1, [7]=1, [9]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=136, text="Channel 136 (5.680 GHz)", region={[1]=1, [7]=1, [9]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=140, text="Channel 140 (5.700 GHz)", region={[1]=1, [7]=1, [9]=1, [12]=1, [13]=1, [14]=1, [18]=1, [19]=1, [21]=1, [22]=1, [30]=1, [31]=1, [32]=1, [33]=1, [36]=1}},
    {channel=144, text="Channel 144 (5.720 GHz)", region={[12]=1, [13]=1, [14]=1}},
    {channel=149, text="Channel 149 (5.745 GHz)", region={[0]=1, [3]=1, [4]=1, [5]=1, [7]=1, [9]=1, [10]=1, [11]=1, [13]=1, [14]=1, [15]=1, [16]=1, [17]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [34]=1, [36]=1, [37]=1}},
    {channel=153, text="Channel 153 (5.765 GHz)", region={[0]=1, [3]=1, [4]=1, [5]=1, [7]=1, [9]=1, [10]=1, [11]=1, [13]=1, [14]=1, [15]=1, [16]=1, [17]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [34]=1, [36]=1, [37]=1}},
    {channel=157, text="Channel 157 (5.785 GHz)", region={[0]=1, [3]=1, [4]=1, [5]=1, [7]=1, [9]=1, [10]=1, [11]=1, [13]=1, [14]=1, [15]=1, [16]=1, [17]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [34]=1, [36]=1, [37]=1}},
    {channel=161, text="Channel 161 (5.805 GHz)", region={[0]=1, [3]=1, [4]=1, [5]=1, [7]=1, [9]=1, [10]=1, [11]=1, [13]=1, [14]=1, [15]=1, [16]=1, [17]=1, [19]=1, [20]=1, [21]=1, [30]=1, [31]=1, [32]=1, [34]=1, [36]=1, [37]=1}},
    {channel=165, text="Channel 165 (5.825 GHz)", region={[0]=1, [4]=1, [7]=1, [9]=1, [10]=1, [13]=1, [14]=1, [15]=1, [16]=1, [30]=1, [31]=1, [34]=1, [36]=1, [37]=1}},
    {channel=169, text="Channel 169 (5.845 GHz)", region={[15]=1}},
    {channel=173, text="Channel 173 (5.865 GHz)", region={[15]=1, [37]=1}},
}

mtkwifi.ChannelList_2G_All = {
    {channel=0, text="Channel 0 (Auto )", region={}},
    {channel= 1, text="Channel  1 (2412 GHz)", region={[0]=1, [1]=1, [5]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 2, text="Channel  2 (2417 GHz)", region={[0]=1, [1]=1, [5]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 3, text="Channel  3 (2422 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 4, text="Channel  4 (2427 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 5, text="Channel  5 (2432 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 6, text="Channel  6 (2437 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 7, text="Channel  7 (2442 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 8, text="Channel  8 (2447 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel= 9, text="Channel  9 (2452 GHz)", region={[0]=1, [1]=1, [5]=1, [6]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel=10, text="Channel 10 (2457 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [5]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel=11, text="Channel 11 (2462 GHz)", region={[0]=1, [1]=1, [2]=1, [3]=1, [5]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel=12, text="Channel 12 (2467 GHz)", region={[1]=1, [3]=1, [5]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel=13, text="Channel 13 (2472 GHz)", region={[1]=1, [3]=1, [5]=1, [7]=1, [31]=1, [32]=1, [33]=1}},
    {channel=14, text="Channel 14 (2477 GHz)", region={[4]=1, [5]=1, [31]=1, [33]=1}},
}

mtkwifi.ChannelList_5G_2nd_80MHZ_ALL = {
    {channel=36, text="Ch36(5.180 GHz) - Ch48(5.240 GHz)", chidx=2},
    {channel=52, text="Ch52(5.260 GHz) - Ch64(5.320 GHz)", chidx=6},
    {channel=-1, text="Channel between 64 100",  chidx=-1},
    {channel=100, text="Ch100(5.500 GHz) - Ch112(5.560 GHz)", chidx=10},
    {channel=112, text="Ch116(5.580 GHz) - Ch128(5.640 GHz)", chidx=14},
    {channel=-1, text="Channel between 128 132", chidx=-1},
    {channel=132, text="Ch132(5.660 GHz) - Ch144(5.720 GHz)", chidx=18},
    {channel=-1, text="Channel between 144 149", chidx=-1},
    {channel=149, text="Ch149(5.745 GHz) - Ch161(5.805 GHz)", chidx=22},
}

local AuthModeList = {
    "Disable",
    "OPEN",--OPENWEP
    "SHARED",--SHAREDWEP
    "WEPAUTO",
    "WPA2",
    "WPA2PSK",
    "WPAPSKWPA2PSK",
    "WPA1WPA2",
    "IEEE8021X",
}

local WpsEnableAuthModeList = {
    "Disable",
    "OPEN",--OPENWEP
    "WPA2PSK",
    "WPAPSKWPA2PSK",
}

local ApCliAuthModeList = {
    "Disable",
    "OPEN",
    "SHARED",
    "WPAPSK",
    "WPA2PSK",
    "WPAPSKWPA2PSK",
    -- "WPA",
    -- "WPA2",
    -- "WPAWPA2",
    -- "8021X",
}

local WPA_Enc_List = {
    "AES",
    "TKIP",
    "TKIPAES",
}


local WEP_Enc_List = {
    "WEP",
}

local dbdc_prefix = {
    {"ra",  "rax"},
    {"rai", "ray"},
    {"rae", "raz"},
}

local dbdc_apcli_prefix = {
    {"apcli",  "apclix"},
    {"apclii", "apcliy"},
    {"apclie", "apcliz"},
}

function mtkwifi.band(mode)
    local i = tonumber(mode)
    if i == 0
    or i == 1
    or i == 4
    or i == 6
    or i == 7
    or i == 9 then
        return "2.4G"
    else
        return "5G"
    end
end


function mtkwifi.__cfg2list(str)
    -- delimeter == ";"
    local i = 1
    local list = {}
    for k in string.gmatch(str, "([^;]+)") do
        list[i] = k
        i = i + 1
    end
    return list
end

function mtkwifi.token_set(str, n, v)
    -- n start from 1
    -- delimeter == ";"
    if not str then return end
    local tmp = mtkwifi.__cfg2list(str)
    if type(v) ~= type("") and type(v) ~= type(0) then
        nixio.syslog("err", "invalid value type in token_set, "..type(v))
        return
    end
    if #tmp < tonumber(n) then
        for i=#tmp, tonumber(n) do
            if not tmp[i] then
                tmp[i] = v -- pad holes with v !
            end
        end
    else
        tmp[n] = v
    end
    return table.concat(tmp, ";")
end


function mtkwifi.token_get(str, n, v)
    -- n starts from 1
    -- v is the backup in case token n is nil
    if not str then return v end
    local tmp = mtkwifi.__cfg2list(str)
    return tmp[tonumber(n)] or v
end

function mtkwifi.search_dev_and_profile_orig()
    local nixio = require("nixio")
    local dir = io.popen("ls /etc/wireless/")
    if not dir then return end
    local result = {}
    -- case 1: mt76xx.dat (best)
    -- case 2: mt76xx.n.dat (multiple card of same dev)
    -- case 3: mt76xx.n.nG.dat (case 2 plus dbdc and multi-profile, bloody hell....)
    for line in dir:lines() do
        -- nixio.syslog("debug", "scan "..line)
        local tmp = io.popen("find /etc/wireless/"..line.." -type f -name \"*.dat\"")
        for datfile in tmp:lines() do
            -- nixio.syslog("debug", "test "..datfile)

            repeat do
            -- for case 1
            local devname = string.match(datfile, "("..line..").dat")
            if devname then
                result[devname] = datfile
                -- nixio.syslog("debug", "yes "..devname.."="..datfile)
                break
            end
            -- for case 2
            local devname = string.match(datfile, "("..line.."%.%d)%.dat")
            if devname then
                result[devname] = datfile
                -- nixio.syslog("debug", "yes "..devname.."="..datfile)
                break
            end
            -- for case 3
            local devname = string.match(datfile, "("..line.."%.%d%.%dG)%.dat")
            if devname then
                result[devname] = datfile
                -- nixio.syslog("debug", "yes "..devname.."="..datfile)
                break
            end
            end until true
        end
    end

    for k,v in pairs(result) do
        nixio.syslog("debug", "search_dev_and_profile_orig: "..k.."="..v)
    end

    return result
end

function mtkwifi.search_dev_and_profile_l1()
    local l1dat = mtkwifi.__get_l1dat()

    if not l1dat then return end

    local nixio = require("nixio")
    local result = {}
    local dbdc_2nd_if = ""

    for k, dev in ipairs(l1dat) do
        dbdc_2nd_if = mtkwifi.token_get(dev.main_ifname, 2, nil)
        if dbdc_2nd_if then
            result[dev["INDEX"].."."..dev["mainidx"]..".1"] = mtkwifi.token_get(dev.profile_path, 1, nil)
            result[dev["INDEX"].."."..dev["mainidx"]..".2"] = mtkwifi.token_get(dev.profile_path, 2, nil)
        else
            result[dev["INDEX"].."."..dev["mainidx"]] = dev.profile_path
        end
    end

    for k,v in pairs(result) do
        nixio.syslog("debug", "search_dev_and_profile_l1: "..k.."="..v)
    end

    return result
end

function mtkwifi.search_dev_and_profile()
    return mtkwifi.search_dev_and_profile_l1() or mtkwifi.search_dev_and_profile_orig()
end

function mtkwifi.__setup_vifs(cfgs, devname, mainidx, subidx)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local prefix
    local main_ifname
    local vifs = {}
    local dev_idx = ""


    prefix = l1dat and l1dat[dridx][devname].ext_ifname or dbdc_prefix[mainidx][subidx]

    dev_idx = string.match(devname, "(%w+)")

    vifs["__prefix"] = prefix
    if (cfgs.BssidNum == nil) then
        debug_write("BssidNum configuration value not found.")
        nixio.syslog("debug","BssidNum configuration value not found.")
        return
    end

    for j=1,tonumber(cfgs.BssidNum) do
        vifs[j] = {}
        vifs[j].vifidx = j -- start from 1
        dev_idx = string.match(devname, "(%w+)")
        main_ifname = l1dat and l1dat[dridx][devname].main_ifname or dbdc_prefix[mainidx][subidx].."0"

        debug_write("setup_vifs", prefix, dev_idx, mainidx, subidx)

        vifs[j].vifname = j == 1 and main_ifname or prefix..(j-1)
        if mtkwifi.exists("/sys/class/net/"..vifs[j].vifname) then
            local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..vifs[j].vifname.."/flags 2>/dev/null")) or 0
            vifs[j].state = flags%2 == 1 and "up" or "down"
        end
        vifs[j].__ssid = cfgs["SSID"..j]
        vifs[j].__bssid = mtkwifi.read_pipe("cat /sys/class/net/"..prefix..(j-1).."/address 2>/dev/null") or "?"
        if dbdc then
            vifs[j].__channel = mtkwifi.token_get(cfgs.Channel, j, 0)
            vifs[j].__wirelessmode = mtkwifi.token_get(cfgs.WirelessMode, j, 0)
        end

        vifs[j].__authmode = mtkwifi.token_get(cfgs.AuthMode, j, "OPEN")
        vifs[j].__encrypttype = mtkwifi.token_get(cfgs.EncrypType, j, "NONE")
        vifs[j].__hidessid = mtkwifi.token_get(cfgs.HideSSID, j, 0)
        vifs[j].__noforwarding = mtkwifi.token_get(cfgs.NoForwarding, j, 0)
        vifs[j].__wmmcapable = mtkwifi.token_get(cfgs.WmmCapable, j, 0)
        vifs[j].__txrate = mtkwifi.token_get(cfgs.TxRate, j, 0)
        vifs[j].__ieee8021x = mtkwifi.token_get(cfgs.IEEE8021X, j, 0)
        vifs[j].__preauth = mtkwifi.token_get(cfgs.PreAuth, j, 0)
        vifs[j].__rekeymethod = mtkwifi.token_get(cfgs.RekeyMethod, j, 0)
        vifs[j].__rekeyinterval = mtkwifi.token_get(cfgs.RekeyInterval, j, 0)
        vifs[j].__pmkcacheperiod = mtkwifi.token_get(cfgs.PMKCachePeriod, j, 0)
        vifs[j].__ht_extcha = mtkwifi.token_get(cfgs.HT_EXTCHA, j, 0)
        vifs[j].__radius_server = mtkwifi.token_get(cfgs.RADIUS_Server, j, 0)
        vifs[j].__radius_port = mtkwifi.token_get(cfgs.RADIUS_Port, j, 0)
        vifs[j].__wepkey_id = mtkwifi.token_get(cfgs.DefaultKeyID, j, 0)
        vifs[j].__wscconfmode = mtkwifi.token_get(cfgs.WscConfMode, j, 0)
        vifs[j].__wepkeys = {
            cfgs["Key1Str"..j],
            cfgs["Key2Str"..j],
            cfgs["Key3Str"..j],
            cfgs["Key4Str"..j],
        }
        vifs[j].__wpapsk = cfgs["WPAPSK"..j]

        -- VoW
        vifs[j].__atc_tp     = mtkwifi.token_get(cfgs.VOW_Rate_Ctrl_En,    j, 0)
        vifs[j].__atc_min_tp = mtkwifi.token_get(cfgs.VOW_Group_Min_Rate,  j, "")
        vifs[j].__atc_max_tp = mtkwifi.token_get(cfgs.VOW_Group_Max_Rate,  j, "")
        vifs[j].__atc_at     = mtkwifi.token_get(cfgs.VOW_Airtime_Ctrl_En, j, 0)
        vifs[j].__atc_min_at = mtkwifi.token_get(cfgs.VOW_Group_Min_Ratio, j, "")
        vifs[j].__atc_max_at = mtkwifi.token_get(cfgs.VOW_Group_Max_Ratio, j, "")

        -- TODO index by vifname
        vifs[vifs[j].vifname] = vifs[j]
    end

    return vifs
end

function mtkwifi.__setup_apcli(cfgs, devname, mainidx, subidx)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local apcli = {}
    local dev_idx = string.match(devname, "(%w+)")
    local apcli_prefix = l1dat and l1dat[dridx][devname].apcli_ifname or
                         dbdc_apcli_prefix[mainidx][subidx]

    local apcli_name = apcli_prefix.."0"

    if mtkwifi.exists("/sys/class/net/"..apcli_name) then
        apcli.vifname = apcli_name
         apcli.vifidx = "1"
        local iwapcli = mtkwifi.read_pipe("iwconfig "..apcli_name.." | grep ESSID 2>/dev/null")

        local _,_,ssid = string.find(iwapcli, "ESSID:\"(.*)\"")
        local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..apcli_name.."/flags 2>/dev/null")) or 0
        apcli.state = flags%2 == 1 and "up" or "down"
        if not ssid or ssid == "" then
            apcli.status = "Disconnected"
        else
            apcli.ssid = ssid
            apcli.status = "Connected"
        end
        apcli.devname = apcli_name
        apcli.bssid = mtkwifi.read_pipe("cat /sys/class/net/"..apcli_name.."/address 2>/dev/null") or "?"
        local flags = tonumber(mtkwifi.read_pipe("cat /sys/class/net/"..apcli_name.."/flags 2>/dev/null")) or 0
        apcli.ifstatus = flags%2 == 1 and "up" or ""
        return apcli
    else
        return
    end
end

function mtkwifi.get_all_devs()
    local nixio = require("nixio")
    local devs = {}
    local i = 1 -- dev idx
    local profiles = mtkwifi.search_dev_and_profile()
    local wpa_support = 0
    local wapi_support = 0

    for devname,profile in pairs(profiles) do
        debug_write("debug", "checking "..profile)

        local fd = io.open(profile,"r")
        if not fd then
            nixio.syslog("debug", "cannot find "..profile)
        else
            fd:close()
            nixio.syslog("debug", "load "..profile)
            debug_write("loading profile"..profile)
            local cfgs = mtkwifi.load_profile(profile)
            if not cfgs then
                debug_write("error loading profile"..profile)
                nixio.syslog("err", "error loading "..profile)
                return
            end
            devs[i] = {}
            devs[i].vifs = {}
            devs[i].apcli = {}
            devs[i].devname = devname
            devs[i].profile = profile
            local tmp = ""
            tmp = string.split(devname, ".")
            devs[i].maindev = tmp[1]
            devs[i].mainidx = tonumber(tmp[2]) or 1
            devs[i].subdev = devname
            devs[i].subidx = string.match(tmp[3] or "", "(%d+)")=="2" and 2 or 1
            devs[i].devband = tonumber(tmp[3])
            if devs[i].devband then
                devs[i].multiprofile = true
                devs[i].dbdc = true
            end
            devs[i].version = mtkwifi.read_pipe("cat /etc/wireless/"..devs[i].maindev.."/version 2>/dev/null") or "unknown"
            devs[i].ApCliEnable = cfgs.ApCliEnable
            devs[i].WirelessMode = cfgs.WirelessMode
            devs[i].WirelessModeList = {}
            for key, value in pairs(DevicePropertyMap) do
                local found = string.find(string.upper(devname), string.upper(value.device))
                if found then
                    for k=1,#value.band do
                        devs[i].WirelessModeList[tonumber(value.band[k])] = WirelessModeList[tonumber(value.band[k])]
                    end
                    devs[i].maxTxStream = value.maxTxStream
                    devs[i].maxRxStream = value.maxRxStream
                    devs[i].invalidChBwList = value.invalidChBwList
                end
            end
            devs[i].WscConfMode = cfgs.WscConfMode
            devs[i].AuthModeList = AuthModeList
            devs[i].WpsEnableAuthModeList = WpsEnableAuthModeList

            if wpa_support == 1 then
                table.insert(devs[i].AuthModeList,"WPAPSK")
                table.insert(devs[i].AuthModeList,"WPA")
            end

            if wapi_support == 1 then
                table.insert(devs[i].AuthModeList,"WAIPSK")
                table.insert(devs[i].AuthModeList,"WAICERT")
            end
            devs[i].ApCliAuthModeList = ApCliAuthModeList
            devs[i].WPA_Enc_List = WPA_Enc_List
            devs[i].WEP_Enc_List = WEP_Enc_List
            devs[i].Channel = tonumber(cfgs.Channel)
            devs[i].DBDC_MODE = tonumber(cfgs.DBDC_MODE)
            devs[i].band = devs[i].devband or mtkwifi.band(cfgs.WirelessMode)

            if cfgs.MUTxRxEnable then
                if tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==0
                    then devs[i].__mimo = 0
                elseif tonumber(cfgs.ETxBfEnCond)==0
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 1
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)==0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 2
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)>0
                    and tonumber(cfgs.ITxBfEn)==0
                    then devs[i].__mimo = 3
                elseif tonumber(cfgs.ETxBfEnCond)==1
                    and tonumber(cfgs.MUTxRxEnable)>0
                    and tonumber(cfgs.ITxBfEn)==1
                    then devs[i].__mimo = 4
                else devs[i].__mimo = 5
                end
            end

            if cfgs.HT_BW == "0" or not cfgs.HT_BW then
                devs[i].__bw = "20"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "0" or not cfgs.VHT_BW then
                if cfgs.HT_BSSCoexistence == "0" or not cfgs.HT_BSSCoexistence then
                    devs[i].__bw = "40"
                else
                    devs[i].__bw = "60" -- 20/40 coexist
                end
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "1" then
                devs[i].__bw = "80"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "2" then
                devs[i].__bw = "160"
            elseif cfgs.HT_BW == "1" and cfgs.VHT_BW == "3" then
                devs[i].__bw = "161"
            end

            devs[i].vifs = mtkwifi.__setup_vifs(cfgs, devname, devs[i].mainidx, devs[i].subidx)
            devs[i].apcli = mtkwifi.__setup_apcli(cfgs, devname, devs[i].mainidx, devs[i].subidx)

            -- Setup reverse indices by devname
            devs[devname] = devs[i]

            if devs[i].apcli then
                devs[i][devs[i].apcli.devname] = devs[i].apcli
            end

            i = i + 1
        end
    end
    return devs
end

function mtkwifi.exists(path)
    local fp = io.open(path, "rb")
    if fp then fp:close() end
    return fp ~= nil
end

function mtkwifi.parse_mac(str)
    local macs = {}
    local pat = "^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]$"

    local function ismac(str)
        if str:match(pat) then return str end
    end

    if not str then return macs end
    local t = str:split("\n")
    for _,v in pairs(t) do
            local mac = ismac(mtkwifi.__trim(v))
            if mac then
                table.insert(macs, mac)
            end
    end

    return macs
    -- body
end


function mtkwifi.scan_ap(vifname)
    os.execute("iwpriv "..vifname.." set SiteSurvey=0")
    os.execute("sleep 10") -- depends on your env
    local scan_result = mtkwifi.read_pipe("iwpriv "..vifname.." get_site_survey 2>/dev/null")
    local nextpageindex = 0;
    local aplist = {}
    local xx = {}
    while (1) do
        nextpageindex = nextpageindex + 31;
        for i, line in ipairs(mtkwifi.__lines(scan_result)) do
            if #line>40 and string.match(line, " BSSID ") then
                xx.Ch = {string.find(line, "Ch "),3}
                xx.SSID = {string.find(line, "SSID "),32}
                local fidx = string.find(line, "SSID_Len")
                if fidx then
                    xx.SSID_len = {fidx,2}
                end
                xx.BSSID = {string.find(line, "BSSID "),17}
                xx.Security = {string.find(line, "Security "),22}
                xx.Signal = {string.find(line, "Sig%a%al"),4}
                xx.Mode = {string.find(line, "W-Mode"),5}
                xx.ExtCh = {string.find(line, "ExtCH"),6}
                xx.WPS = {string.find(line, "WPS"),3}
                xx.NT = {string.find(line, "NT"),2}
            end

            local tmp = {}
            if #line>40 and not string.match(line, " BSSID ") then
                tmp = {}
                tmp.channel = mtkwifi.__trim(string.sub(line, xx.Ch[1], xx.Ch[1]+xx.Ch[2]))
                if xx.SSID_len then
                    -- Maximum (xx.SSID[2] + 1) characters are supported in SSID
                    tmp.ssid_len = tonumber(mtkwifi.__trim(string.sub(line, xx.SSID_len[1], xx.SSID_len[1]+xx.SSID_len[2]))) or (xx.SSID[2] + 1)
                    if tmp.ssid_len > (xx.SSID[2] + 1) or tmp.ssid_len < 0 then
                        tmp.ssid_len = (xx.SSID[2] + 1)
                    end
                    tmp.ssid = string.sub(line, xx.SSID[1], xx.SSID[1]+tmp.ssid_len - 1)
                else
                    tmp.ssid = mtkwifi.__trim(string.sub(line, xx.SSID[1], xx.SSID[1]+xx.SSID[2]))
                    tmp.ssid_len = tmp.ssid:len()
                end
                tmp.bssid = string.upper(mtkwifi.__trim(string.sub(line, xx.BSSID[1], xx.BSSID[1]+xx.BSSID[2])))
                tmp.security = mtkwifi.__trim(string.sub(line, xx.Security[1], xx.Security[1]+xx.Security[2]))
                tmp.authmode = mtkwifi.__trim(string.split(tmp.security, "/")[1])
                tmp.encrypttype = mtkwifi.__trim(string.split(tmp.security, "/")[2] or "NONE")
                tmp.rssi = mtkwifi.__trim(string.sub(line, xx.Signal[1], xx.Signal[1]+xx.Signal[2]))
                tmp.extch = mtkwifi.__trim(string.sub(line, xx.ExtCh[1], xx.ExtCh[1]+xx.ExtCh[2]))
                tmp.mode = mtkwifi.__trim(string.sub(line, xx.Mode[1], xx.Mode[1]+xx.Mode[2]))
                tmp.wps = mtkwifi.__trim(string.sub(line, xx.WPS[1], xx.WPS[1]+xx.WPS[2]))
                tmp.nt = mtkwifi.__trim(string.sub(line, xx.NT[1], xx.NT[1]+xx.NT[2]))
                table.insert(aplist, tmp)
            end
        end

        scan_result = mtkwifi.read_pipe("iwpriv "..vifname.." get_site_survey "..nextpageindex)
        local num_line = 0;
        for k, _ in ipairs(mtkwifi.__lines(scan_result)) do
            num_line = num_line + 1
        end

        if num_line < 4 then
            break;
        end
    end

    return aplist
end

function mtkwifi.__any_wsc_enabled(wsc_conf_mode)
    if (wsc_conf_mode == "") then
        return 0;
    end
    if (wsc_conf_mode == "7") then
        return 1;
    end
    if (wsc_conf_mode == "4") then
        return 1;
    end
    if (wsc_conf_mode == "2") then
        return 1;
    end
    if (wsc_conf_mode == "1") then
        return 1;
    end
    return 0;
end

function mtkwifi.__restart_if_wps(devname, ifname, cfgs)
    local devs = mtkwifi.get_all_devs()
    local ssid_index = devs[devname]["vifs"][ifname].vifidx
    local wsc_conf_mode = ""

    wsc_conf_mode=mtkwifi.token_get(cfgs["WscConfMode"], ssid_index, "")

    os.execute("iwpriv "..ifname.." set WscConfMode=0")
    debug_write("iwpriv "..ifname.." set WscConfMode=0")
    os.execute("route delete 239.255.255.250")
    debug_write("route delete 239.255.255.250")
    if(mtkwifi.__any_wsc_enabled(wsc_conf_mode)) then
        os.execute("iwpriv "..ifname.." set WscConfMode=7")
        debug_write("iwpriv "..ifname.." set WscConfMode=7")
        os.execute("route add -host 239.255.255.250 dev br0")
        debug_write("route add -host 239.255.255.250 dev br0")
    end

    -- execute wps_action.lua file to send signal for current interface
    os.execute("lua wps_action.lua "..ifname)
    debug_write("lua wps_action.lua "..ifname)
    return cfgs
end

function mtkwifi.restart_8021x(devname, devices)
    local l1dat, l1 = mtkwifi.__get_l1dat()
    local dridx = l1dat and l1.DEV_RINDEX

    local devs = devices or mtkwifi.get_all_devs()
    local dev = devs[devname]
    local main_ifname = l1dat and l1dat[dridx][devname].main_ifname or dbdc_prefix[mainidx][subidx].."0"
    local prefix = l1dat and l1dat[dridx][devname].ext_ifname or dbdc_prefix[mainidx][subidx]

    local ps_cmd = "ps | grep -v grep | grep rt2860apd | grep "..main_ifname.." | awk '{print $1}'"
    local pid_cmd = "cat /var/run/rt2860apd_"..devs[devname].vifs[1].vifname..".pid"
    local apd_pid = mtkwifi.read_pipe(pid_cmd) or mtkwifi.read_pipe(ps_cmd)
    if tonumber(apd_pid) then
        os.execute("kill "..apd_pid)
    end

    local cfgs = mtkwifi.load_profile(devs[devname].profile)
    local auth_mode = cfgs['AuthMode']
    local ieee8021x = cfgs['IEEE8021X']
    local pat_auth_mode = {"WPA$", "WPA;", "WPA2$", "WPA2;", "WPA1WPA2$", "WPA1WPA2;"}
    local pat_ieee8021x = {"1$", "1;"}
    local apd_en = false

    for _, pat in ipairs(pat_auth_mode) do
        if string.find(auth_mode, pat) then
            apd_en = true
        end
    end

    for _, pat in ipairs(pat_ieee8021x) do
        if string.find(ieee8021x, pat) then
            apd_en = true
        end
    end

    if not apd_en then
        return
    end

    os.execute("rt2860apd -i "..main_ifname.." -p "..prefix)
end

function mtkwifi.dat2uci(datfile, ucifile)
    local shuci = require("shuci")
    local cfgs = mtkwifi.load_profile(datfile)

    local uci = {}

    uci["wifi-device"]={}
    uci["wifi-device"][".name"] = device
    uci["wifi-device"]["type"] = device
    uci["wifi-device"]["vendor"] = "ralink"
    uci["wifi-device"]["iface"] = {}

    local i = 1 -- index of wifi-iface

    uci["iface"] = {}
    while i <= tonumber(cfgs.BssidNum) do
        uci["iface"][i] = {}
        local iface = uci["iface"][i]
        iface["ssid"] = cfgs["SSID"..(i)]
        iface["mode"] = "ap"
        iface["network"] = "lan"
        iface["ifname"] = "ra0"
        iface[".name"] = device.."."..iface["ifname"]

        i=i+1
    end

    shuci.encode(uci, ucifile)
end

function mtkwifi.uci2dat(ucifile, devname, datfile)
    local shuci = require("shuci")
    local uci = shuci.decode(ucifile)
    local cfgs = mtkwifi.load_profile(datfile) or {}

    if not ucifile or not devname then return end

    for _,dev in ipairs(uci["wifi-device"][devname]) do
        for k,v in pairs(dev) do
            if string.byte(k) ~= string.byte(".")
            and string.byte(k) ~= string.byte("_") then
                cfgs.k = v
            end
        end
    end
    if datfile then
        save_profile(cfgs, datfile)
    end
end

return mtkwifi
