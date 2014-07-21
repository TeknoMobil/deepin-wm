//
//  Copyright (C) 2014 Tom Beckmann
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Meta;

namespace Gala.Plugins.Notify
{
	public enum NotificationUrgency
	{
		LOW = 0,
		NORMAL = 1,
		CRITICAL = 2
	}

	public enum NotificationClosedReason
	{
		EXPIRED = 1,
		DISMISSED = 2,
		CLOSE_NOTIFICATION_CALL = 3,
		UNDEFINED = 4
	}

	[DBus (name = "org.freedesktop.DBus")]
	private interface DBus : Object
	{
		[DBus (name = "GetConnectionUnixProcessID")]
		public abstract uint32 get_connection_unix_process_id (string name) throws Error;
	}

	[DBus (name = "org.freedesktop.Notifications")]
	public class NotifyServer : Object
	{
		const int DEFAULT_TMEOUT = 4000;
		const string FALLBACK_ICON = "dialog-information";

		[DBus (visible = false)]
		public signal void show_notification (Notification notification);

		public signal void notification_closed (uint32 id, uint32 reason);
		public signal void action_invoked (uint32 id, string action_key);

		[DBus (visible = false)]
		public NotificationStack stack { get; construct; }

		uint32 id_counter = 0;

		DBus? bus_proxy = null;

		public NotifyServer (NotificationStack stack)
		{
			Object (stack: stack);
		}

		construct
		{
			try {
				bus_proxy = Bus.get_proxy_sync (BusType.SESSION, "org.freedesktop.DBus", "/");
			} catch (Error e) {
				warning (e.message);
				bus_proxy = null;
			}
		}

		public string [] get_capabilities ()
		{
			return {
				"body",
				"body-markup",
				"x-canonical-private-synchronous",
				"x-canonical-private-icon-only"
			};
		}

		public void get_server_information (out string name, out string vendor,
			out string version, out string spec_version)
		{
			name = "pantheon-notify";
			vendor = "elementaryOS";
			version = "0.1";
			spec_version = "1.1";
		}

		/**
		 * Implementation of the CloseNotification DBus method
		 *
		 * @param id The id of the notification to be closed.
		 */
		public void close_notification (uint32 id) throws DBusError
		{
			foreach (var child in stack.get_children ()) {
				unowned Notification notification = (Notification) child;
				if (notification.id == id) {
					notification_closed_callback (notification, id,
						NotificationClosedReason.CLOSE_NOTIFICATION_CALL);
					notification.close ();
					return;
				}
			}

			// according to spec, an empty dbus error should be sent if the notification
			// doesn't exist (anymore)
			throw new DBusError.FAILED ("");
		}

		public new uint32 notify (string app_name, uint32 replaces_id, string app_icon, string summary, 
			string body, string[] actions, HashTable<string, Variant> hints, int32 expire_timeout, BusName sender)
		{
			var id = replaces_id != 0 ? replaces_id : ++id_counter;
			var pixbuf = get_pixbuf (hints, app_name, app_icon);
			var timeout = expire_timeout == uint32.MAX ? DEFAULT_TMEOUT : expire_timeout;
			var urgency = hints.contains ("urgency") ?
				(NotificationUrgency) hints.lookup ("urgency").get_byte () : NotificationUrgency.NORMAL;

			var icon_only = hints.contains ("x-canonical-private-icon-only");
			var confirmation = hints.contains ("x-canonical-private-synchronous");
			var progress = confirmation && hints.contains ("value");

#if true //debug notifications
			print ("Notification from '%s', replaces: %u\n" +
				"\tapp icon: '%s'\n\tsummary: '%s'\n\tbody: '%s'\n\tn actions: %u\n\texpire: %i\n\tHints:\n",
				app_name, replaces_id, app_icon, summary, body, actions.length);
			hints.@foreach ((key, val) => {
				print ("\t\t%s => %s\n", key, val.is_of_type (VariantType.STRING) ?
					val.get_string () : "<" + val.get_type ().dup_string () + ">");
			});
#endif

			uint32 pid = 0;
			try {
				pid = bus_proxy.get_connection_unix_process_id (sender);
			} catch (Error e) { warning (e.message); }

			foreach (var child in stack.get_children ()) {
				unowned Notification notification = (Notification) child;

				if (notification.being_destroyed)
					continue;

				// we only want a single confirmation notification, so we just take the
				// first one that can be found, no need to check ids or anything
				var confirmation_notification = notification as ConfirmationNotification;
				if (confirmation && confirmation_notification != null) {
					confirmation_notification.update (pixbuf,
						progress ? hints.@get ("value").get_int32 () : -1,
						hints.@get ("x-canonical-private-synchronous").get_string (),
						icon_only);

					return id;
				}

				var normal_notification = notification as NormalNotification;
				if (!confirmation
					&& notification.id == id
					&& !notification.being_destroyed
					&& normal_notification != null) {

					if (normal_notification != null)
						normal_notification.update (summary, body, pixbuf, timeout, actions);

					return id;
				}
			}

			Notification notification;
			if (confirmation)
				notification = new ConfirmationNotification (id, pixbuf, icon_only,
					progress ? hints.@get ("value").get_int32 () : -1,
					hints.@get ("x-canonical-private-synchronous").get_string ());
			else
				notification = new NormalNotification (stack.screen, id, summary, body, pixbuf,
					urgency, timeout, pid, actions);

			notification.closed.connect (notification_closed_callback);
			stack.show_notification (notification);

			return id;
		}

		Gdk.Pixbuf? get_pixbuf (HashTable<string, Variant> hints, string app, string icon)
		{
			// decide on the icon, order:
			// - image-data
			// - image-path
			// - app_icon
			// - icon_data
			// - from app name?
			// - fallback to dialog-information

			Gdk.Pixbuf? pixbuf = null;
			var size = Notification.ICON_SIZE;

			var mask_offset = 4;
			var mask_size_offset = mask_offset * 2;
			var has_mask = false;

			if (hints.contains ("image_data") || hints.contains ("image-data")) {

				has_mask = true;
				size = size - mask_size_offset;

				var data = hints.contains ("image_data") ?
					hints.lookup ("image_data") : hints.lookup ("image-data");
				pixbuf = load_from_variant_at_size (data, size);

			} else if (hints.contains ("image-path") || hints.contains ("image_path")) {

				var image_path = (hints.contains ("image-path") ?
					hints.lookup ("image-path") : hints.lookup ("image_path")).get_string ();

				try {
					if (image_path.has_prefix ("file://") || image_path.has_prefix ("/")) {
						has_mask = true;
						size = size - mask_size_offset;

						var file_path = File.new_for_commandline_arg (image_path).get_path ();
						pixbuf = new Gdk.Pixbuf.from_file_at_scale (file_path, size, size, true);
					} else {
						pixbuf = Gtk.IconTheme.get_default ().load_icon (image_path, size, 0);
					}
				} catch (Error e) { warning (e.message); }

			} else if (icon != "") {

				try {
					var themed = new ThemedIcon.with_default_fallbacks (icon);
					var info = Gtk.IconTheme.get_default ().lookup_by_gicon (themed, size, 0);
					if (info != null)
						pixbuf = info.load_icon ();
				} catch (Error e) { warning (e.message); }

			} else if (hints.contains ("icon_data")) {

				has_mask = true;
				size = size - mask_size_offset;

				var data = hints.lookup ("icon_data");
				pixbuf = load_from_variant_at_size (data, size);

			}

			if (pixbuf == null) {

				try {
					pixbuf = Gtk.IconTheme.get_default ().load_icon (app.down (), size, 0);
				} catch (Error e) {

					try {
						pixbuf = Gtk.IconTheme.get_default ().load_icon (FALLBACK_ICON, size, 0);
					} catch (Error e) { warning (e.message); }
				}
			} else if (has_mask) {
				var mask_size = Notification.ICON_SIZE;
				var offset_x = mask_offset;
				var offset_y = mask_offset + 1;

				var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, mask_size, mask_size);
				var cr = new Cairo.Context (surface);

				Granite.Drawing.Utilities.cairo_rounded_rectangle (cr,
					offset_x, offset_y, size, size, 4);
				cr.clip ();

				Gdk.cairo_set_source_pixbuf (cr, pixbuf, offset_x, offset_y);
				cr.paint ();

				cr.reset_clip ();

				var mask = new Cairo.ImageSurface.from_png (Config.PKGDATADIR + "/image-mask.png");
				cr.set_source_surface (mask, 0, 0);
				cr.paint ();

				pixbuf = Gdk.pixbuf_get_from_surface (surface, 0, 0, mask_size, mask_size);
			}

			return pixbuf;
		}

		static Gdk.Pixbuf? load_from_variant_at_size (Variant variant, int size)
		{
			if (!variant.is_of_type (new VariantType ("(iiibiiay)"))) {
				critical ("notify icon/image-data format invalid");
				return null;
			}

			int width, height, rowstride, bits_per_sample, n_channels;
			bool has_alpha;

			variant.get ("(iiibiiay)", out width, out height, out rowstride,
				out has_alpha, out bits_per_sample, out n_channels, null);

			var data = variant.get_child_value (6);
			unowned uint8[] pixel_data = (uint8[]) data.get_data ();

			var pixbuf = new Gdk.Pixbuf.with_unowned_data (pixel_data, Gdk.Colorspace.RGB, has_alpha, bits_per_sample, width, height, rowstride, null);
			return pixbuf.scale_simple (size, size, Gdk.InterpType.BILINEAR);
		}		

		void notification_closed_callback (Notification notification, uint32 id, uint32 reason)
		{
			notification.closed.disconnect (notification_closed_callback);

			notification_closed (id, reason);
		}
	}
}

