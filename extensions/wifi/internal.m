#import <Cocoa/Cocoa.h>
#import <CoreWLAN/CoreWLAN.h>
#import <lauxlib.h>

static int wifi_gc(lua_State* L __unused) {
    return 0;
}

CWInterface *get_wifi_interface() {
    return [CWInterface interfaceWithName:nil];
}

/// hs.wifi.availableNetworks() -> table
/// Function
/// Returns a list of available WiFi networks
/// WARNING: This function will block all Lua execution until the scan has completed. It's probably not
/// very sensible to use this function very much, if at all.
static int wifi_scan(lua_State* L __unused) {
    CWInterface *interface = get_wifi_interface();
    NSSet *availableNetworks = [interface scanForNetworksWithName:nil error:nil];
    if (!availableNetworks) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);
    int i = 1;
    for (CWNetwork *network in [availableNetworks allObjects]) {
        lua_pushnumber(L, i++);
        lua_pushstring(L, [[network ssid] UTF8String]);
        lua_settable(L, -3);
    }

    return 1;
}

/// hs.wifi.currentNetwork() -> string or nil
/// Function
/// Returns the SSID of the currently associated WiFi network, or nil if no network is associated
static int wifi_current_ssid(lua_State* L) {
    CWInterface *interface = get_wifi_interface();
    if (interface) {
        lua_pushstring(L, [[interface ssid] UTF8String]);
    } else {
        lua_pushnil(L);
    }

    return 1;
}

static const luaL_Reg wifilib[] = {
    {"availableNetworks", wifi_scan},
    {"currentNetwork", wifi_current_ssid},

    {}
};

static const luaL_Reg metalib[] = {
    {"__gc", wifi_gc},

    {}
};

int luaopen_hs_wifi_internal(lua_State* L) {
    luaL_newlib(L, wifilib);
    luaL_newlib(L, metalib);
    lua_setmetatable(L, -2);

    return 1;
}
