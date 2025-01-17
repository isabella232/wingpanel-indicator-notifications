/*-
 * Copyright 2015-2020 elementary, Inc. (https://elementary.io)
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

public class Notifications.Indicator : Wingpanel.Indicator {
    private const string[] EXCEPTIONS = { "NetworkManager", "gnome-settings-daemon", "gnome-power-panel" };
    private const string CHILD_SCHEMA_ID = "io.elementary.notifications.applications";
    private const string CHILD_PATH = "/io/elementary/notifications/applications/%s/";
    private const string REMEMBER_KEY = "remember";

    private Gee.HashMap<string, Settings> app_settings_cache;
    private GLib.Settings notify_settings;
    private Gtk.Grid? main_box = null;
    private Gtk.ModelButton clear_all_btn;
    private Gtk.Spinner? dynamic_icon = null;
    private NotificationsList nlist;
    private List<Notification> previous_session = null;

    public Indicator () {
        Object (
            code_name: Wingpanel.Indicator.MESSAGES,
            visible: true
        );
    }

    construct {
        GLib.Intl.bindtextdomain (Notifications.GETTEXT_PACKAGE, Notifications.LOCALEDIR);
        GLib.Intl.bind_textdomain_codeset (Notifications.GETTEXT_PACKAGE, "UTF-8");

        notify_settings = new GLib.Settings ("io.elementary.notifications");
        app_settings_cache = new Gee.HashMap<string, Settings> ();
    }

    public override Gtk.Widget get_display_widget () {
        if (dynamic_icon == null) {
            Gtk.IconTheme.get_default ().add_resource_path ("/io/elementary/wingpanel/notifications");

            var provider = new Gtk.CssProvider ();
            provider.load_from_resource ("io/elementary/wingpanel/notifications/indicator.css");

            dynamic_icon = new Gtk.Spinner () {
                active = true,
                tooltip_markup = _("Updating notifications…")
            };

            unowned var dynamic_icon_style_context = dynamic_icon.get_style_context ();
            dynamic_icon_style_context.add_provider (provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            dynamic_icon_style_context.add_class ("notification-icon");

            nlist = new NotificationsList ();

            var monitor = NotificationMonitor.get_instance ();
            monitor.notification_received.connect (on_notification_received);
            monitor.notification_closed.connect (on_notification_closed);

            notify_settings.changed["do-not-disturb"].connect (() => {
                set_display_icon_name ();
            });

            dynamic_icon.button_press_event.connect ((e) => {
                if (e.button == Gdk.BUTTON_MIDDLE) {
                    notify_settings.set_boolean ("do-not-disturb", !notify_settings.get_boolean ("do-not-disturb"));
                    return Gdk.EVENT_STOP;
                }

                return Gdk.EVENT_PROPAGATE;
            });

            previous_session = Session.get_instance ().get_session_notifications ();
            Timeout.add (2000, () => { // Do not block animated drawing of wingpanel
                load_session_notifications.begin (() => { // load asynchromously so spinner continues to rotate
                    set_display_icon_name ();
                    nlist.add.connect (set_display_icon_name);
                    nlist.remove.connect (set_display_icon_name);
                });

                return Source.REMOVE;
            });
        }

        return dynamic_icon;
    }

    private async void load_session_notifications () {
        foreach (var notification in previous_session) {
            yield nlist.add_entry (notification, false); // This is slow as NotificationEntry is complex
        }
    }

    public override Gtk.Widget? get_widget () {
        if (main_box == null) {
            var not_disturb_switch = new Granite.SwitchModelButton (_("Do Not Disturb"));
            not_disturb_switch.get_style_context ().add_class (Granite.STYLE_CLASS_H4_LABEL);

            var dnd_switch_separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 3,
                margin_bottom = 3
            };

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.max_content_height = 500;
            scrolled.propagate_natural_height = true;
            scrolled.add (nlist);

            var clear_all_btn_separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 3,
                margin_bottom = 3
            };

            clear_all_btn = new Gtk.ModelButton ();
            clear_all_btn.text = _("Clear All Notifications");

            var settings_btn = new Gtk.ModelButton ();
            settings_btn.text = _("Notifications Settings…");

            main_box = new Gtk.Grid ();
            main_box.orientation = Gtk.Orientation.VERTICAL;
            main_box.width_request = 300;
            main_box.add (not_disturb_switch);
            main_box.add (dnd_switch_separator);
            main_box.add (scrolled);
            main_box.add (clear_all_btn_separator);
            main_box.add (clear_all_btn);
            main_box.add (settings_btn);
            main_box.show_all ();

            notify_settings.bind ("do-not-disturb", not_disturb_switch, "active", GLib.SettingsBindFlags.DEFAULT);

            nlist.close_popover.connect (() => close ());
            nlist.add.connect (update_clear_all_sensitivity);
            nlist.remove.connect (update_clear_all_sensitivity);

            clear_all_btn.clicked.connect (() => {
                nlist.clear_all ();
                Session.get_instance ().clear ();
            });

            settings_btn.clicked.connect (show_settings);
        }

        return main_box;
    }

    public override void opened () {
        update_clear_all_sensitivity ();
    }

    public override void closed () {

    }

    private void on_notification_received (DBusMessage message, uint32 id) {
        var notification = new Notification.from_message (message, id);
        if (notification.is_transient || notification.app_name in EXCEPTIONS) {
            return;
        }

        string app_id = notification.desktop_id.replace (Notification.DESKTOP_ID_EXT, "");

        Settings? app_settings = app_settings_cache.get (app_id);

        var schema = SettingsSchemaSource.get_default ().lookup (CHILD_SCHEMA_ID, true);
        if (schema != null && app_settings == null && app_id != "") {
            app_settings = new Settings.full (schema, null, CHILD_PATH.printf (app_id));
            app_settings_cache.set (app_id, app_settings);
        }

        if (app_settings == null || app_settings.get_boolean (REMEMBER_KEY)) {
            nlist.add_entry.begin (notification, true);
        }

        set_display_icon_name ();
    }

    private void update_clear_all_sensitivity () {
        clear_all_btn.sensitive = nlist.app_entries.size > 0;
    }

    private void on_notification_closed (uint32 id) {
        foreach (var app_entry in nlist.app_entries.values) {
            foreach (var item in app_entry.app_notifications) {
                if (item.notification.id == id) {
                    item.notification.close ();
                    return;
                }
            }
        }
    }

    private void set_display_icon_name () {
        unowned var dynamic_icon_style_context = dynamic_icon.get_style_context ();
        if (notify_settings.get_boolean ("do-not-disturb")) {
            dynamic_icon_style_context.add_class ("disabled");
        } else if (nlist != null && nlist.app_entries.size > 0) {
            dynamic_icon_style_context.remove_class ("disabled");
            dynamic_icon_style_context.add_class ("new");
        } else {
            dynamic_icon_style_context.remove_class ("disabled");
            dynamic_icon_style_context.remove_class ("new");
        }
        update_tooltip ();
    }

    private void show_settings () {
        close ();

        try {
            AppInfo.launch_default_for_uri ("settings://notifications", null);
        } catch (Error e) {
            warning ("Failed to open notifications settings: %s", e.message);
        }
    }

    private void update_tooltip () {
        uint number_of_notifications = Session.get_instance ().count_notifications ();
        int number_of_apps = nlist.app_entries.size;
        string description;
        string accel_label;

        if (notify_settings.get_boolean ("do-not-disturb")) {
            accel_label = _("Middle-click to disable Do Not Disturb");
        } else {
            accel_label = _("Middle-click to enable Do Not Disturb");
        }

        accel_label = Granite.TOOLTIP_SECONDARY_TEXT_MARKUP.printf (accel_label);

        switch (number_of_notifications) {
            case 0:
                description = _("No notifications");
                break;
            case 1:
                description = _("1 notification");
                break;
            default:
                /// TRANSLATORS: A tooltip text for the indicator representing the number of notifications.
                /// e.g. "2 notifications from 1 app" or "5 notifications from 3 apps"
                description = _("%s from %s").printf (
                    dngettext (GETTEXT_PACKAGE, "%u notification", "%u notifications", number_of_notifications).printf (number_of_notifications),
                    dngettext (GETTEXT_PACKAGE, "%i app", "%i apps", number_of_apps).printf (number_of_apps)
                );
                break;
        }

        dynamic_icon.tooltip_markup = "%s\n%s".printf (description, accel_label);
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    debug ("Activating Notifications Indicator");

    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    var indicator = new Notifications.Indicator ();
    return indicator;
}
