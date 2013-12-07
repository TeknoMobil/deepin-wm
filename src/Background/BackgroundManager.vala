//  
//  Copyright (C) 2013 Tom Beckmann, Rico Tzschichholz
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
#if HAS_MUTTER38
	public class BackgroundManager : Meta.BackgroundGroup
	{
		public Meta.Screen screen { get; construct; }

		public BackgroundManager (Meta.Screen screen)
		{
			Object (screen: screen);
		}
		
		construct
		{
			screen.monitors_changed.connect (update);

			update ();
		}

		~BackgroundManager ()
		{
			screen.monitors_changed.disconnect (update);
		}

		void update ()
		{
			remove_all_children ();

			var settings = BackgroundSettings.get_default ().schema;

			for (var i = 0; i < screen.get_n_monitors (); i++) {
				var geom = screen.get_monitor_geometry (i);
				var background = new Background (screen, i, settings);

				background.set_position (geom.x, geom.y);
				background.set_size (geom.width, geom.height);

				add_child (background);
			}
		}
	}
#endif
}
