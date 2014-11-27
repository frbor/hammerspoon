#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <lauxlib.h>

// ----------------------- Definitions ---------------------

#define USERDATA_TAG "hs.menubar"
#define get_item_arg(L, idx) ((menubaritem_t *)luaL_checkudata(L, idx, USERDATA_TAG))
#define lua_to_nsstring(L, idx) [NSString stringWithUTF8String:luaL_checkstring(L, idx)]

// Define a base object for our various callback handlers
@interface HSMenubarCallbackObject : NSObject
@property lua_State *L;
@property int fn;
@end
@implementation HSMenubarCallbackObject
@end

// Define some basic helper functions
void parse_table(lua_State *L, int idx, NSMenu *menu);
void erase_menu_items(lua_State *L, NSMenu *menu);
void callback_runner(HSMenubarCallbackObject *self);

// Define a datatype for hs.menubar meta-objects
typedef struct _menubaritem_t {
    void *menuBarItemObject;
    void *click_callback;
    int click_fn;
} menubaritem_t;

// Define an array to track delegates for dynamic menu objects
NSMutableArray *dynamicMenuDelegates;

// Define an object for delegate objects to handle clicks on menubar items that have no menu, but wish to act on clicks
@interface HSMenubarItemClickDelegate : HSMenubarCallbackObject
@end
@implementation HSMenubarItemClickDelegate
- (void) click:(id __unused)sender {
    callback_runner(self);
}
@end

// Define an object for dynamic menu objects
@interface HSMenubarItemMenuDelegate : HSMenubarCallbackObject <NSMenuDelegate>
@end
@implementation HSMenubarItemMenuDelegate
- (void) menuNeedsUpdate:(NSMenu *)menu {
    callback_runner(self);
    // Ensure the callback returned a table, then remove any existing menu structure and parse the table into a new menu
    luaL_checktype(self.L, lua_gettop(self.L), LUA_TTABLE);
    erase_menu_items(self.L, menu);
    parse_table(self.L, lua_gettop(self.L), menu);
}
@end

// ----------------------- Helper functions ---------------------

// Generic callback runner that will execute a Lua function stored in self.fn
void callback_runner(HSMenubarCallbackObject *self) {
    lua_State *L = self.L;
    lua_getglobal(L, "debug"); lua_getfield(L, -1, "traceback"); lua_remove(L, -2);
    lua_rawgeti(L, LUA_REGISTRYINDEX, self.fn);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        NSLog(@"%s", lua_tostring(L, -1));
        lua_getglobal(L, "hs"); lua_getfield(L, -1, "showError"); lua_remove(L, -2);
        lua_pushvalue(L, -2);
        lua_pcall(L, 1, 0, 0);
        return;
    }
}

// Helper function to parse a Lua table and turn it into an NSMenu hierarchy (is recursive, so may do terrible things on huge tables)
void parse_table(lua_State *L, int idx, NSMenu *menu) {
    lua_pushnil(L); // Push a nil to the top of the stack, which lua_next() will interpret as "fetch the first item of the table"
    while (lua_next(L, idx) != 0) {
        // lua_next pushed two things onto the stack, the table item's key at -2 and its value at -1

        // Check that the value is a table
        if (lua_type(L, -1) != LUA_TTABLE) {
            NSLog(@"Error: table entry is not a menu item table");

            // Pop the value off the stack, leaving the key at the top
            lua_pop(L, 1);
            // Bail to the next lua_next() call
            continue;
        }

        // Inspect the menu item table at the top of the stack, fetch the value for the key "title" and push the result to the top of the stack
        lua_getfield(L, -1, "title");
        if (!lua_isstring(L, -1)) {
            // We can't proceed without the title, we'd have nothing to display in the menu, so let's just give up and move on
            NSLog(@"Error: malformed menu table entry");
            // We need to pop two things off the stack - the result of lua_getfield and the table it inspected
            lua_pop(L, 2);
            // Bail to the next lua_next() call
            continue;
        }

        // We have found the title of a menu bar item. Turn it into an NSString and pop it off the stack
        NSString *title = lua_to_nsstring(L, -1); //[NSString stringWithUTF8String:luaL_checkstring(L, -1)];
        lua_pop(L, 1);

        if ([title isEqualToString:@"-"]) {
            [menu addItem:[NSMenuItem separatorItem]];
        } else {
            NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];

            // Check to see if we have a submenu, if so, recurse into it
            lua_getfield(L, -1, "menu");
            if (lua_istable(L, -1)) {
                NSMenu *subMenu = [[NSMenu alloc] initWithTitle:@"HammerspoonSubMenu"];
                parse_table(L, lua_gettop(L), subMenu);
                [menuItem setSubmenu:subMenu];
            }
            lua_pop(L, 1);

            // Inspect the menu item table at the top of the stack, fetch the value for the key "fn" and push the result to the top of the stack
            lua_getfield(L, -1, "fn");
            if (lua_isfunction(L, -1)) {
                HSMenubarItemClickDelegate *delegate = [[HSMenubarItemClickDelegate alloc] init];

                // luaL_ref is going to store a reference to the item at the top of the stack and then pop it off. To avoid confusion, we're going to push the top item on top of itself, so luaL_ref leaves us where we are now
                lua_pushvalue(L, -1);
                delegate.fn = luaL_ref(L, LUA_REGISTRYINDEX);
                delegate.L = L;
                [menuItem setTarget:delegate];
                [menuItem setAction:@selector(click:)];
                [menuItem setRepresentedObject:delegate];
            }
            // Pop the result of fetching "fn", off the stack
            lua_pop(L, 1);

            // Check if this item is enabled/disabled, defaulting to enabled
            lua_getfield(L, -1, "disabled");
            if (lua_isboolean(L, -1)) {
                [menuItem setEnabled:lua_toboolean(L, -1)];
            } else {
                [menuItem setEnabled:YES];
            }
            lua_pop(L, 1);

            // Check if this item is checked/unchecked, defaulting to unchecked
            lua_getfield(L, -1, "checked");
            if (lua_isboolean(L, -1)) {
                [menuItem setState:lua_toboolean(L, -1) ? NSOnState : NSOffState];
            } else {
                [menuItem setState:NSOffState];
            }
            lua_pop(L, 1);

            [menu addItem:menuItem];
        }
        // Pop the menu item table off the stack, leaving its key at the top, for lua_next()
        lua_pop(L, 1);
    }
}

// Recursively remove all items from a menu, de-allocating their delegates as we go
void erase_menu_items(lua_State *L, NSMenu *menu) {
    for (NSMenuItem *menuItem in [menu itemArray]) {
        HSMenubarItemClickDelegate *target = [menuItem representedObject];
        if (target) {
            luaL_unref(L, LUA_REGISTRYINDEX, target.fn);
            [menuItem setTarget:nil];
            [menuItem setAction:nil];
            [menuItem setRepresentedObject:nil];
            target = nil;
        }
        if ([menuItem hasSubmenu]) {
            erase_menu_items(L, [menuItem submenu]);
            [menuItem setSubmenu:nil];
        }
        [menu removeItem:menuItem];
    }
}

// Remove and clean up a dynamic menu delegate
void erase_menu_delegate(lua_State *L, NSMenu *menu) {
    HSMenubarItemMenuDelegate *delegate = [menu delegate];
    if (delegate) {
        luaL_unref(L, LUA_REGISTRYINDEX, delegate.fn);
        [dynamicMenuDelegates removeObject:delegate];
        [menu setDelegate:nil];
        delegate = nil;
    }

    return;
}

// Remove any kind of menu on a menubar item
void erase_all_menu_parts(lua_State *L, NSStatusItem *statusItem) {
   NSMenu *menu = [statusItem menu];

   if (menu) {
       erase_menu_delegate(L, menu);
       erase_menu_items(L, menu);
       [statusItem setMenu:nil];
   }

   return;
}

// ----------------------- API implementations ---------------------

/// hs.menubar.new() -> menubaritem
/// Constructor
/// Creates a new menu bar item object, which can be added to the system menubar by calling menubaritem:add()
/// Returns nil if the object could not be created
///
/// Note: You likely want to call either hs.menubar:setTitle() or hs.menubar:setIcon() after creating a menubar item, otherwise it will be invisible.
static int menubarNew(lua_State *L) {
    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    NSStatusItem *statusItem = [statusBar statusItemWithLength:NSVariableStatusItemLength];

    if (statusItem) {
        menubaritem_t *menuBarItem = lua_newuserdata(L, sizeof(menubaritem_t));
        memset(menuBarItem, 0, sizeof(menubaritem_t));

        menuBarItem->menuBarItemObject = (__bridge_retained void*)statusItem;
        menuBarItem->click_callback = nil;
        menuBarItem->click_fn = 0;

        luaL_getmetatable(L, USERDATA_TAG);
        lua_setmetatable(L, -2);
    } else {
        lua_pushnil(L);
    }

    return 1;
}

/// hs.menubar:setTitle(title)
/// Method
/// Sets the text on a menubar item. If an icon is also set, this text will be displayed next to the icon
static int menubarSetTitle(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);
    NSString *titleText = lua_to_nsstring(L, 2); //[NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    lua_settop(L, 1); // FIXME: This seems unnecessary? neither preceeding luaL_foo function pushes things onto the stack?
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setTitle:titleText];

    return 0;
}

/// hs.menubar:setIcon(iconfilepath) -> bool
/// Method
/// Loads the image specified by iconfilepath and sets it as the menu bar item's icon.
/// Returns true if the image was set, or nil if it could not be found
// FIXME: Talk about icon requirements, wrt size/colour and general suitability for retina and yosemite dark mode
static int menubarSetIcon(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);
    NSImage *iconImage = [[NSImage alloc] initWithContentsOfFile:lua_to_nsstring(L, 2)];//[NSString stringWithUTF8String:luaL_checkstring(L, 2)]];
    lua_settop(L, 1); // FIXME: This seems unnecessary?
    if (!iconImage) {
        lua_pushnil(L);
        return 1;
    }
    [iconImage setTemplate:YES];
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setImage:iconImage];

    lua_pushboolean(L, 1);
    return 1;
}

/// hs.menubar:setTooltip(tooltip)
/// Method
/// Sets the tooltip text on a menubar item.
static int menubarSetTooltip(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);
    NSString *toolTipText = lua_to_nsstring(L, 2); //[NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    lua_settop(L, 1); // FIXME: This seems unnecessary?
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setToolTip:toolTipText];

    return 0;
}

/// hs.menubar:setClickCallback(fn)
///
/// Method
/// Registers a function to be called when the menubar icon is clicked. If the argument is nil, the previously registered callback is removed.
/// Note: If a menu has been attached to the menubar item, this callback will never be called
static int menubarSetClickCallback(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;
    if (lua_isnil(L, 2)) {
        if (menuBarItem->click_fn) {
            luaL_unref(L, LUA_REGISTRYINDEX, menuBarItem->click_fn);
            menuBarItem->click_fn = 0;
        }
        if (menuBarItem->click_callback) {
            [statusItem setTarget:nil];
            [statusItem setAction:nil];
            HSMenubarItemClickDelegate *object = (__bridge_transfer HSMenubarItemClickDelegate *)menuBarItem->click_callback;
            menuBarItem->click_callback = nil;
            object = nil;
        }
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION);
        lua_pushvalue(L, 2);
        menuBarItem->click_fn = luaL_ref(L, LUA_REGISTRYINDEX);
        HSMenubarItemClickDelegate *object = [[HSMenubarItemClickDelegate alloc] init];
        object.L = L;
        object.fn = menuBarItem->click_fn;
        menuBarItem->click_callback = (__bridge_retained void*) object;
        [statusItem setTarget:object];
        [statusItem setAction:@selector(click:)];
    }
    return 0;
}

/// hs.menubar:setMenu(items or fn or nil)
/// Method
/// If the argument is nil:
///   Removes any previously registered menu
/// If the argument is a table:
///   Sets the menu for this menubar item to the supplied table, or removes the menu if the argument is nil
///    {{ title = "my menu item", fn = function() print("you clicked!") end }, { title = "other item", fn = some_function } }
/// If the argument is a function:
///   Adds a menu to this menubar item, supplying a callback that will be called when the menu needs to update (i.e. when the user clicks on the menubar item).
///   The callback should return a table describing the structure and properties of the menu. Its format should be identical to that of the argument to hs.menubar:setMenu()
///   If the argument is nil, removes any previously registered callback
static int menubarSetMenu(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;
    NSMenu *menu = nil;
    HSMenubarItemMenuDelegate *delegate = nil;

    // We always need to start by erasing any pre-existing menu stuff
    erase_all_menu_parts(L, statusItem);

    switch (lua_type(L, 2)) {
        case LUA_TTABLE:
            menu = [[NSMenu alloc] initWithTitle:@"HammerspoonMenuItemStaticMenu"];
            if (menu) {
                [menu setAutoenablesItems:NO];
                parse_table(L, 2, menu);

                // If the table returned no useful menu items, we might as well get rid of the menu
                if ([menu numberOfItems] == 0) {
                    menu = nil;
                }
            }
            break;

        case LUA_TFUNCTION:
            menu = [[NSMenu alloc] initWithTitle:@"HammerspoonMenuItemDynamicMenu"];
            if (menu) {
                [menu setAutoenablesItems:NO];

                delegate = [[HSMenubarItemMenuDelegate alloc] init];
                delegate.L = L;
                lua_pushvalue(L, 2);
                delegate.fn = luaL_ref(L, LUA_REGISTRYINDEX);
                [dynamicMenuDelegates addObject:delegate];
            }
            break;
    }

    if (menu) {
        [statusItem setMenu:menu];
        if (delegate) {
            [menu setDelegate:delegate];
        }
    }

    return 0;
}

/// hs.menubar:delete(menubaritem)
/// Method
/// Removes the menubar item from the menubar and destroys it
static int menubar_delete(lua_State *L) {
    menubaritem_t *menuBarItem = get_item_arg(L, 1);

    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;

    // Remove any click callbackery the menubar item has
    lua_pushcfunction(L, menubarSetClickCallback);
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_call(L, 2, 0);

    // Remove all menu stuff associated with this item
    erase_all_menu_parts(L, statusItem);

    [statusBar removeStatusItem:(__bridge NSStatusItem*)menuBarItem->menuBarItemObject];
    menuBarItem->menuBarItemObject = nil;
    menuBarItem = nil;

    return 0;
}

// ----------------------- Lua/hs glue GAR ---------------------

static int menubar_setup(lua_State* __unused L) {
    if (!dynamicMenuDelegates) {
        dynamicMenuDelegates = [[NSMutableArray alloc] init];
    }
    return 0;
}

static int menubar_gc(lua_State* __unused L) {
    //FIXME: We should really be removing all menubar items here, as well as doing:
    //[dynamicMenuDelegates removeAllObjects];
    //dynamicMenuDelegates = nil;
    return 0;
}

static int menubaritem_gc(lua_State *L) {
    lua_pushcfunction(L, menubar_delete) ; lua_pushvalue(L, 1); lua_call(L, 1, 1);
    return 0;
}

static const luaL_Reg menubarlib[] = {
    {"new", menubarNew},

    {}
};

static const luaL_Reg menubar_metalib[] = {
    {"setTitle", menubarSetTitle},
    {"setIcon", menubarSetIcon},
    {"setTooltip", menubarSetTooltip},
    {"setClickCallback", menubarSetClickCallback},
    {"setMenu", menubarSetMenu},
    {"delete", menubar_delete},

    {"__gc", menubaritem_gc},
    {}
};

static const luaL_Reg menubar_gclib[] = {
    {"__gc", menubar_gc},

    {}
};

/* NOTE: The substring "hs_menubar_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.menubar.internal". */

int luaopen_hs_menubar_internal(lua_State *L) {
    menubar_setup(L);

    // Metatable for created objects
    luaL_newlib(L, menubar_metalib);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_setfield(L, LUA_REGISTRYINDEX, USERDATA_TAG);

    // Table for luaopen
    luaL_newlib(L, menubarlib);
    luaL_newlib(L, menubar_gclib);
    lua_setmetatable(L, -2);

    return 1;
}