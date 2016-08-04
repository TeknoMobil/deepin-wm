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

namespace Gala
{
	public class BackgroundSource : Object
	{
		public signal void changed (int[] workspaces);

		public Meta.Screen screen { get; construct; }
		public Settings settings { get; construct; }
		public Settings extra_settings { get; construct; }

		internal int use_count { get; set; default = 0; }

		Gee.HashMap<string,Background> backgrounds;
        string fallback_background_name = "/usr/share/backgrounds/default_background.jpg";

		public BackgroundSource (Meta.Screen screen, string settings_schema,
								 string extra_settings_schema)
		{
			Object (screen: screen, settings: new Settings (settings_schema),
					extra_settings: new Settings (extra_settings_schema));
		}

		construct
		{
			backgrounds = new Gee.HashMap<string,Background> ();

			screen.monitors_changed.connect (monitors_changed);

			settings_hash_cache = get_current_settings_hash_cache ();
			cache_extra_picture_uris = get_current_extra_picture_uris ();

            screen.workspace_added.connect (on_workspace_added);
            screen.workspace_removed.connect (on_workspace_removed);

			//settings.changed.connect (settings_changed);
			//extra_settings.changed.connect (settings_changed);
		}

        void on_workspace_removed (int index)
        {
            delete_background (index);
        }

        void on_workspace_added (int index)
        {
			string default_uri = settings.get_string ("picture-uri");
            change_background (index, default_uri);
        }

        // change background for workspace index, this may not expand array
        public void change_background (int index, string uri)
        {
            stderr.printf("change_background(%d, %s)\n", index, uri);

            var nr_ws = screen.get_n_workspaces ();
            if (index >= nr_ws) return;

            string old = get_picture_filename (0, index);
            if (old == uri) return;

			string default_uri = settings.get_string ("picture-uri");
			string[] extra_uris = extra_settings.get_strv ("background-uris");

            // keep sync with workspace length
            if (extra_uris.length > nr_ws) {
                extra_uris.resize (nr_ws);
            } else if (extra_uris.length < nr_ws) {
                int oldsz = extra_uris.length;
                extra_uris.resize (nr_ws);
                for (int i = oldsz; i < nr_ws; i++) {
                    extra_uris[i] = default_uri;
                }
            }

            extra_uris[index] = uri;
            extra_uris += null;
            extra_settings.set_strv ("background-uris", extra_uris);


            notify_changed (index);
        }

        void notify_changed (int index, bool send_signal = true)
        {
			var n = screen.get_n_monitors ();
			string[] to_remove = {};

			foreach (var key in backgrounds.keys) {
				var background = backgrounds[key];
				var indexes = key.split(":");
				var workspace_index = indexes[1].to_int ();
                if (workspace_index == index) {
                    to_remove += key;
                    background.destroy ();
                }
			}

            for (int i = 0; i < to_remove.length; i++) {
				backgrounds.unset (to_remove[i]);
			}

            if (send_signal)
                changed (new int[] {index});
        }

        public void delete_background (int index)
        {
            stderr.printf("delete_background(%d)\n", index);
            var nr_ws = screen.get_n_workspaces ();
            if (index > nr_ws) return;

			string default_uri = settings.get_string ("picture-uri");
			string[] extra_uris = extra_settings.get_strv ("background-uris");

            if (index >= extra_uris.length) return;

            var len = extra_uris.length;
            extra_uris.move (index + 1, index, len - index - 1);
            extra_uris.resize (len-1);

            // keep sync with workspace length
            if (extra_uris.length > nr_ws) {
                extra_uris.resize (nr_ws);
            } else if (extra_uris.length < nr_ws) {
                int oldsz = extra_uris.length;
                extra_uris.resize (nr_ws);
                for (int i = oldsz; i < nr_ws; i++) {
                    extra_uris[i] = default_uri;
                }
            }
            extra_uris += null;
            extra_settings.set_strv ("background-uris", extra_uris);

            notify_delete (index, false);
        }

        void notify_delete (int index, bool send_signal = true)
        {
			var n = screen.get_n_monitors ();

            for (var i = 0; i < n; i++) {
                string key = @"$i:$index";
                if (backgrounds.has_key (key)) {
                    var background = backgrounds[key];
                    backgrounds.remove (key);
                    background.destroy ();
                }
            }

			for (var i = 0; i < n; i++) {
                for (var j = index+1; j < screen.get_n_workspaces ()+1; j++) {
                    string key = @"$i:$j";
                    if (backgrounds.has_key (key)) {
                        var background = backgrounds[key];
                        backgrounds.remove (key);

                        string new_key = @"$i:$(j-1)";
                        backgrounds[new_key] = background;
                    }
                }
			}

            if (send_signal)
                changed (new int[] {index});
        }

		void monitors_changed ()
		{
			var n = screen.get_n_monitors ();
			var keys_to_remove = new List<string> ();

			foreach (var key in backgrounds.keys) {
				var background = backgrounds[key];
				var indexes = key.split(":");
				var monitor_index = indexes[0].to_int ();
				var workspace_index = indexes[1].to_int ();
				if (monitor_index < n) {
					background.update_resolution ();
					continue;
				}

				background.destroy ();

				keys_to_remove.append (key);
			}

			foreach (var key in  keys_to_remove) {
				backgrounds.unset (key);
			}
		}

		public Background get_background (int monitor_index, int workspace_index)
		{
			string? filename = null;

			var style = settings.get_enum ("picture-options");
			if (style != GDesktop.BackgroundStyle.NONE) {
				filename = get_picture_filename (monitor_index, workspace_index);
			}

			// Animated backgrounds are (potentially) per-monitor, since
			// they can have variants that depend on the aspect ratio and
			// size of the monitor; for other backgrounds we can use the
			// same background object for all monitors.
			//if (filename == null || !filename.has_suffix (".xml"))
			if (filename == null)
				monitor_index = 0;

			string key = "%d:%d".printf (monitor_index, workspace_index);
            Meta.verbose ("%s: key = %s\n", Log.METHOD, key);
			if (!backgrounds.has_key (key)) {
				var background = new Background (screen, monitor_index, workspace_index, filename,
												 this, (GDesktop.BackgroundStyle) style);
				backgrounds[key] = background;
			}

			return backgrounds[key];
		}

		string get_picture_filename (int monitor_index, int workspace_index)
		{
			string filename = null;
			string default_uri = settings.get_string ("picture-uri");

			string[] extra_uris = extra_settings.get_strv ("background-uris");

			string uri;
            if (extra_uris.length > 0 && extra_uris.length > workspace_index) {
                uri = extra_uris[workspace_index];
                if (uri == "") {
                    uri = default_uri;
                }
            } else {
                uri = default_uri;
            }

			if (Uri.parse_scheme (uri) != null) {
				var file = File.new_for_uri (uri);
                if (file.query_exists ()) {
                    filename = file.get_path ();
                }
			} else {
				filename = uri;
			}

            if (filename == null) {
                return fallback_background_name;
            }

			return filename;
		}

		void background_changed ()
		{
            Meta.verbose ("BackgroundSource::%s\n", Log.METHOD);

            foreach (var key in backgrounds.keys) {
                var background = backgrounds[key];
                background.destroy ();
            }
            backgrounds.clear ();

			//changed ();
		}

		public void destroy ()
		{
			screen.monitors_changed.disconnect (monitors_changed);

			foreach (var background in backgrounds.values) {
				background.destroy ();
			}

			screen.workspace_added.disconnect (on_workspace_added);
			screen.workspace_removed.disconnect (on_workspace_removed);
		}

		// unfortunately the settings sometimes tend to fire random changes even though
		// nothing actually happend. The code below is used to prevent us from spamming
		// new actors all the time, which lead to some problems in other areas of the code

		// helper struct which stores the hash values generated by g_variant_hash
		struct SettingsHashCache
		{
			uint color_shading_type;
			uint picture_opacity;
			uint picture_options;
			uint picture_uri;
			uint primar_color;
			uint secondary_color;
		}

		SettingsHashCache settings_hash_cache;
		Variant cache_extra_picture_uris;

		// list of keys that are actually relevant for us
		const string[] options = { "color-shading-type", "picture-opacity",
								   "picture-options", "picture-uri", "primary-color", "secondary-color",
								   "background-uris"};

		void settings_changed (string key)
		{
			if (!(key in options))
				return;

			var current = get_current_settings_hash_cache ();
			var current_extra = get_current_extra_picture_uris ();

			if (Memory.cmp (&settings_hash_cache, &current, sizeof (SettingsHashCache)) == 0 &&
				cache_extra_picture_uris.equal (current_extra)) {
				return;
			}

			Memory.copy (&settings_hash_cache, &current, sizeof (SettingsHashCache));
			cache_extra_picture_uris = current_extra;


            background_changed ();
		}

		SettingsHashCache get_current_settings_hash_cache ()
		{
			return {
				settings.get_value ("color-shading-type").hash (),
				settings.get_value ("picture-opacity").hash (),
				settings.get_value ("picture-options").hash (),
				settings.get_value ("picture-uri").hash (),
				settings.get_value ("primary-color").hash (),
				settings.get_value ("secondary-color").hash (),
			};
		}

		Variant get_current_extra_picture_uris ()
		{
			return extra_settings.get_value ("background-uris");
		}
	}
}
