/*-
 * Copyright (c) 2015 Wingpanel Developers (http://launchpad.net/wingpanel)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

public class Indicator : Wingpanel.Indicator {
    private const string[] EXCEPTIONS = { "wingpanel-indicator-sound", "indicator-sound", "NetworkManager", "gnome-settings-daemon", "gnome-power-panel" };
    private const string CHILD_SCHEMA_ID = "org.pantheon.desktop.gala.notifications.application";
    private const string CHILD_PATH = "/org/pantheon/desktop/gala/notifications/applications/%s/";
    private const string REMEMBER_KEY = "remember";

    private const uint16 BOX_WIDTH = 300;
    private const uint16 BOX_HEIGHT = 400;
    private const string LIST_ID = "list";
    private const string NO_NOTIFICATIONS_ID = "no-notifications";

    private Wingpanel.Widgets.OverlayIcon? dynamic_icon = null;
    private Gtk.Box? main_box = null;
    private Wingpanel.Widgets.Button clear_all_btn;
    private Gtk.Stack stack;

    private NotificationsList nlist;

    private Gee.HashMap<string, Settings> app_settings_cache;

    public Indicator () {
        Object (code_name: Wingpanel.Indicator.MESSAGES,
                display_name: _("Notifications indicator"),
                description:_("The notifications indicator"));

        visible = true;

        app_settings_cache = new Gee.HashMap<string, Settings> ();
        Utils.init ();
    }

    public override Gtk.Widget get_display_widget () {
        if (dynamic_icon == null)
            dynamic_icon = new Wingpanel.Widgets.OverlayIcon (get_display_icon_name ());

        dynamic_icon.button_press_event.connect ((e) => {
            if (e.button == Gdk.BUTTON_MIDDLE) {
                NotifySettings.get_instance ().do_not_disturb = !NotifySettings.get_instance ().do_not_disturb;
                return Gdk.EVENT_STOP;
            }

            return Gdk.EVENT_PROPAGATE;
        });

        return dynamic_icon;
    }

    public override Gtk.Widget? get_widget () {
        if (main_box == null) {
            main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            main_box.set_size_request (BOX_WIDTH, -1);

            stack = new Gtk.Stack ();
            stack.hexpand = true;

            var no_notifications_label = new Gtk.Label (_("No Notifications"));
            no_notifications_label.get_style_context ().add_class ("h2");
            no_notifications_label.sensitive = false;
            no_notifications_label.margin_top = no_notifications_label.margin_bottom = 24;
            no_notifications_label.margin_start = no_notifications_label.margin_end = 12;

            nlist = new NotificationsList ();

            var scrolled = new Wingpanel.Widgets.AutomaticScrollBox (null, null);
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.add_with_viewport (nlist);

            stack.add_named (scrolled, LIST_ID);
            stack.add_named (no_notifications_label, NO_NOTIFICATIONS_ID);

            var not_disturb_switch = new Wingpanel.Widgets.Switch (_("Do Not Disturb"), NotifySettings.get_instance ().do_not_disturb);
            not_disturb_switch.get_label ().get_style_context ().add_class ("h4");
            not_disturb_switch.get_switch ().notify["active"].connect (() => {
                NotifySettings.get_instance ().do_not_disturb = not_disturb_switch.get_switch ().active;
            });

            clear_all_btn = new Wingpanel.Widgets.Button (_("Clear All Notifications"));
            clear_all_btn.clicked.connect (() => {
                nlist.clear_all ();
                Session.get_instance ().clear ();
            });

            var settings_btn = new Wingpanel.Widgets.Button (_("Notifications Settings…"));
            settings_btn.clicked.connect (show_settings);

            nlist.close_popover.connect (() => close ());
            nlist.switch_stack.connect (on_switch_stack);
            NotificationMonitor.get_instance ().received.connect (on_notification_received);

            NotifySettings.get_instance ().changed[NotifySettings.DO_NOT_DISTURB_KEY].connect (() => {
                not_disturb_switch.get_switch ().active = NotifySettings.get_instance ().do_not_disturb;
                dynamic_icon.set_main_icon_name (get_display_icon_name ());
            });

            main_box.add (not_disturb_switch);
            main_box.add (new Wingpanel.Widgets.Separator ());
            main_box.add (stack);
            main_box.add (new Wingpanel.Widgets.Separator ());
            main_box.pack_end (settings_btn, false, false, 0);
            main_box.pack_end (clear_all_btn, false, false, 0);
            main_box.show_all ();

            restore_previous_session ();

            dynamic_icon.set_main_icon_name (get_display_icon_name ());
        }

        return main_box;
    }

    public override void opened () {

    }

    public override void closed () {

    }

    private void on_notification_received (DBusMessage message, uint32 id) {
        var notification = new Notification.from_message (message, id);
        if (!notification.get_is_valid () || notification.app_name in EXCEPTIONS) {
            return;
        }

        string app_id = notification.desktop_id.replace (Notification.DESKTOP_ID_EXT, "");
        if (!((DesktopAppInfo)notification.app_info).get_boolean ("X-GNOME-UsesNotifications")) {
            app_id = "gala-other";
        }

        Settings? app_settings = app_settings_cache.get (app_id);

        var schema = SettingsSchemaSource.get_default ().lookup (CHILD_SCHEMA_ID, true);
        if (schema != null && app_settings == null && app_id != "") {
            app_settings = new Settings.full (schema, null, CHILD_PATH.printf (app_id));
            app_settings_cache.set (app_id, app_settings);
        }

        if (app_settings == null || app_settings.get_boolean (REMEMBER_KEY)) {
            var entry = new NotificationEntry (notification);
            nlist.add_entry (entry);
        }

        dynamic_icon.set_main_icon_name (get_display_icon_name ());        
    }

    private void on_switch_stack (bool show_list) {
        clear_all_btn.sensitive = show_list;
        if (show_list) {
            stack.set_visible_child_name (LIST_ID);
        } else {
            stack.set_visible_child_name (NO_NOTIFICATIONS_ID);
        }

        dynamic_icon.set_main_icon_name (get_display_icon_name ());        
    }

    private void restore_previous_session () {
        var previous_session = Session.get_instance ().get_session_notifications ();
        previous_session.foreach ((notification) => {
            nlist.add_entry (new NotificationEntry (notification));
        });
    }

    private string get_display_icon_name () {
        if (NotifySettings.get_instance ().do_not_disturb) {
            return "notification-disabled-symbolic";
        } else if (nlist != null && nlist.get_entries_length () > 0) {
            return "notification-new-symbolic";
        }
        
        return "notification-symbolic";
    }

    private void show_settings () {
        close ();

        var list = new List<string> ();
        list.append ("notifications");

        try {
            var appinfo = AppInfo.create_from_commandline ("switchboard", null, AppInfoCreateFlags.SUPPORTS_URIS);
            appinfo.launch_uris (list, null);
        } catch (Error e) {
            warning ("%s\n", e.message);
        }
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    debug ("Activating Notifications Indicator");

    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    var indicator = new Indicator ();
    return indicator;
}
