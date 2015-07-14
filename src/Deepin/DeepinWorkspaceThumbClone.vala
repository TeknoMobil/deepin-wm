//
//  Copyright (C) 2014 Deepin, Inc.
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

using Clutter;
using Meta;

namespace Gala
{
	/**
	 * Workspace thumnail clone with background, normal windows and
	 * workspace names.  It also support dragging and dropping to
	 * move and close workspaces.
	 */
	public class DeepinWorkspaceThumbClone : Actor
	{
		const int WORKSPACE_NAME_WIDTH = 80;
		const int WORKSPACE_NAME_HEIGHT = 18;
		const int WORKSPACE_NAME_MAX_LENGTH = 32;

		// distance between thumbnail workspace clone and workspace
		// name field
		const int WORKSPACE_NAME_DISTANCE = 20;

		// layout spacing for workspace name field
		const int WORKSPACE_NAME_SPACING = 5;

		const int SHAPE_PADDING = 5;

		const int SHOW_CLOSE_BUTTON_DELAY = 200;

		/**
		 * The group has been clicked. The MultitaskingView should consider activating
		 * its workspace.
		 */
		public signal void selected ();

		public Workspace workspace { get; construct; }

		public Actor? fallback_key_focus = null;

		// selected shape for workspace thumbnail clone
		Actor thumb_shape;

		// selected shape for workspace name field
		DeepinCssActor name_shape;

		Actor workspace_shadow;
		Actor workspace_clone;
		Actor background;
		DeepinWindowCloneThumbContainer window_container;

		Actor workspace_name;
		Text workspace_name_num;
		Text workspace_name_text;

		Actor close_button;

		uint show_close_button_timeout_id = 0;

		public DeepinWorkspaceThumbClone (Workspace workspace)
		{
			Object (workspace: workspace);
		}

		construct
		{
			reactive = true;

			// workspace shadow effect
			workspace_shadow = new Actor ();
			workspace_shadow.add_effect_with_name ("shadow", new ShadowEffect (get_thumb_workspace_prefer_width (),
																			   get_thumb_workspace_prefer_heigth (), 10, 1));
			add_child (workspace_shadow);

			workspace.get_screen ().monitors_changed.connect (update_workspace_shadow);

			// selected shape for workspace thumbnail clone
			thumb_shape = new DeepinCssStaticActor ("deepin-workspace-thumb-clone", Gtk.StateFlags.SELECTED);
			thumb_shape.opacity = 0;
			thumb_shape.set_easing_mode (DeepinMultitaskingView.WORKSPACE_ANIMATION_MODE);
			add_child (thumb_shape);

			// workspace thumbnail clone
			workspace_clone = new Actor ();
			int radius = DeepinUtils.get_css_border_radius ("deepin-workspace-thumb-clone", Gtk.StateFlags.SELECTED);
			workspace_clone.add_effect (new DeepinRoundRectEffect (radius));
			add_child (workspace_clone);

			background = new DeepinFramedBackground (workspace.get_screen (), false, false);
			background.button_press_event.connect (() => {selected (); return true;});
			workspace_clone.add_child (background);

			window_container = new DeepinWindowCloneThumbContainer (workspace);
			window_container.window_activated.connect ((w) => selected ());
			workspace_clone.add_child (window_container);

			// selected shape for workspace name field
			name_shape = new DeepinCssActor ("deepin-workspace-thumb-clone-name");
			name_shape.reactive = true;
			name_shape.set_easing_mode (DeepinMultitaskingView.WORKSPACE_ANIMATION_MODE);

			name_shape.button_press_event.connect (on_name_button_press_event);

			add_child (name_shape);

			// workspace name field
			workspace_name = new Actor ();
			workspace_name.layout_manager = new BoxLayout ();

			var name_font = DeepinUtils.get_css_font ("deepin-workspace-thumb-clone-name");

			workspace_name_num = new Text ();
			workspace_name_num.set_easing_mode (DeepinMultitaskingView.WORKSPACE_ANIMATION_MODE);
			workspace_name_num.set_font_description (name_font);

			workspace_name_text = new Text ();
			workspace_name_text.reactive = true;
			workspace_name_text.activatable = true;
			workspace_name_text.cursor_size = 1;
			workspace_name_text.ellipsize = Pango.EllipsizeMode.END;
			workspace_name_text.max_length = WORKSPACE_NAME_MAX_LENGTH;
			workspace_name_text.single_line_mode = true;
			workspace_name_text.set_easing_mode (DeepinMultitaskingView.WORKSPACE_ANIMATION_MODE);
			workspace_name_text.set_font_description (name_font);
			workspace_name_text.selection_color = DeepinUtils.get_css_background_color ("deepin-text-selection");
			workspace_name_text.selected_text_color = DeepinUtils.get_css_color ("deepin-text-selection");

			workspace_name_text.button_press_event.connect (on_name_button_press_event);
			workspace_name_text.activate.connect (() => {
				get_stage ().set_key_focus (fallback_key_focus);
				workspace_name_text.editable = false;
				workspace_name.queue_relayout ();
			});
			workspace_name_text.key_focus_in.connect (() => {
				// make cursor visible even through workspace name is empty,
				// maybe this is a bug of Clutter.Text
				if (workspace_name_text.text.length == 0) {
					workspace_name_text.text = " ";
					workspace_name_text.text = "";
				}
			});
			workspace_name_text.key_focus_out.connect (set_workspace_name);

			get_workspace_name ();

			workspace_name.add_child (workspace_name_num);
			workspace_name.add_child (workspace_name_text);
			add_child (workspace_name);

			// close button
			close_button = Utils.create_close_button ();
			close_button.opacity = 0;
			close_button.reactive = true;
			close_button.visible = false;
			close_button.set_easing_duration (200);

			// block propagation of button presses on the close button, otherwise
			// the click action on the WorkspaceTHumbClone will act weirdly
			close_button.button_press_event.connect (() => { return true; });

			var close_click = new ClickAction ();
			close_click.clicked.connect (remove_workspace);
			close_button.add_action (close_click);

			var click = new ClickAction ();
			click.clicked.connect (() => selected ());
			// When the actor is pressed, the ClickAction grabs all events, so we won't be
			// notified when the cursor leaves the actor, which makes our close button stay
			// forever. To fix this we hide the button for as long as the actor is pressed.
			click.notify["pressed"].connect (() => {
				toggle_close_button (!click.pressed && get_has_pointer ());
			});
			add_action (click);

			add_child (close_button);
		}

		~DeepinWorkspaceThumbClone ()
		{
			workspace.get_screen ().monitors_changed.disconnect (update_workspace_shadow);
			background.destroy ();
		}

		public override bool enter_event (CrossingEvent event)
		{
			toggle_close_button (true);
			return false;
		}

		public override bool leave_event (CrossingEvent event)
		{
			if (!contains (event.related)) {
				toggle_close_button (false);
			}

			return false;
		}

		bool on_name_button_press_event ()
		{
			if (workspace_name_text.editable && workspace_name_text.has_key_focus ()) {
				return false;
			}

			grab_key_focus_for_name ();

			// select current workspace if workspace name is editable
			selected ();

			// Return false to let event continue to be passed, so the cursor
			// will be put in the position of the mouse.
			return false;
		}

		public void grab_key_focus_for_name ()
		{
			workspace_name_text.grab_key_focus ();
			workspace_name_text.editable = true;
		}

		public void set_workspace_name ()
		{
			Prefs.change_workspace_name (workspace.index (), workspace_name_text.text);
		}

		public void get_workspace_name ()
		{
			workspace_name_num.text = "%d".printf (workspace.index () + 1);
			workspace_name_text.text = DeepinUtils.get_workspace_name (workspace.index ());
		}

		public void select (bool value, bool animate = true)
		{
			int duration = animate ? AnimationSettings.get_default ().workspace_switch_duration : 0;

			// selected shape for workspace thumbnail clone
			thumb_shape.save_easing_state ();

			thumb_shape.set_easing_duration (duration);
			thumb_shape.opacity = value ? 255 : 0;

			thumb_shape.restore_easing_state ();

			// selected shape for workspace name field
			name_shape.save_easing_state ();

			name_shape.set_easing_duration (duration);
			name_shape.select = value;

			name_shape.restore_easing_state ();

			// font color for workspace name field
			workspace_name_num.save_easing_state ();
			workspace_name_text.save_easing_state ();

			workspace_name_num.set_easing_duration (duration);
			workspace_name_text.set_easing_duration (duration);
			var text_color = DeepinUtils.get_css_color ("deepin-workspace-thumb-clone-name",
														value ? Gtk.StateFlags.SELECTED : Gtk.StateFlags.NORMAL);
			workspace_name_num.color = text_color;
			workspace_name_text.color = text_color;

			workspace_name_num.restore_easing_state ();
			workspace_name_text.restore_easing_state ();
		}

		public void select_window (Window window)
		{
			window_container.select_window (window);
		}

		void update_workspace_shadow ()
		{
			var shadow_effect = workspace_clone.get_effect ("shadow") as ShadowEffect;
			if (shadow_effect != null) {
				shadow_effect.update_size (get_thumb_workspace_prefer_width (), get_thumb_workspace_prefer_heigth ());
			}
		}

		int get_thumb_workspace_prefer_width ()
		{
			var monitor_geom = DeepinUtils.get_primary_monitor_geometry (workspace.get_screen ());
			return (int) (monitor_geom.width * DeepinWorkspaceThumbCloneContainer.WORKSPACE_WIDTH_PERCENT);
		}

		int get_thumb_workspace_prefer_heigth ()
		{
			var monitor_geom = DeepinUtils.get_primary_monitor_geometry (workspace.get_screen ());
			return (int) (monitor_geom.height * DeepinWorkspaceThumbCloneContainer.WORKSPACE_WIDTH_PERCENT);
		}

		/**
		 * Requests toggling the close button. If show is true, a timeout will
		 * be set after which the close button is shown, if false, the close
		 * button is hidden and the timeout is removed, if it exists. The close
		 * button may not be shown even though requested if the workspaces are
		 * set to be dynamic.
		 *
		 * @param show Whether to show the close button
		 */
		void toggle_close_button (bool show)
		{
			// don't display the close button when we have dynamic workspaces or
			// when there is only one workspace
			if (Prefs.get_dynamic_workspaces () || Prefs.get_num_workspaces () == 1) {
				return;
			}

			if (show_close_button_timeout_id != 0) {
				Source.remove (show_close_button_timeout_id);
				show_close_button_timeout_id = 0;
			}

			if (show) {
				show_close_button_timeout_id = Timeout.add (SHOW_CLOSE_BUTTON_DELAY, () => {
					close_button.visible = true;
					close_button.opacity = 255;
					show_close_button_timeout_id = 0;
					return false;
				});
				return;
			}

			close_button.opacity = 0;
			var transition = get_transition ("opacity");
			if (transition != null) {
				transition.completed.connect (() => {
					close_button.visible = false;
				});
			} else {
				close_button.visible = false;
			}
		}

		// TODO: necessary?
		/**
		 * Remove all currently added WindowIconActors
		 */
		public void clear ()
		{
			window_container.destroy_all_children ();
		}

		/**
		 * Creates a Clone for the given window and adds it to the group
		 */
		public void add_window (Window window)
		{
			window_container.add_window (window);
		}

		/**
		 * Remove the Clone for a MetaWindow from the container
		 */
		public void remove_window (Window window)
		{
			window_container.remove_window (window);
		}

		/*
		 * Remove current workspace and moving all the windows to preview
		 * workspace.
		 */
		void remove_workspace ()
		{
			var screen = workspace.get_screen ();
			if (Prefs.get_num_workspaces () <= 1) {
				// there is only one workspace, ignored
				return;
			}

			// do not store old workspace name in gsettings
			DeepinUtils.reset_all_workspace_names ();

			// TODO: animation
			opacity = 0;
			var transition = workspace_clone.get_transition ("opacity");
			if (transition != null) {
				// stdout.printf ("transition is not null\n");// TODO:
				transition.completed.connect (do_close_workspace);
			} else {
				// stdout.printf ("transition is null\n");// TODO:
				do_close_workspace ();
			}

		}
		void do_close_workspace ()
		{
			var screen = workspace.get_screen ();
			uint32 timestamp = screen.get_display ().get_current_time ();
			screen.remove_workspace (workspace, timestamp);
		}

		public override void allocate (ActorBox box, AllocationFlags flags)
		{
			base.allocate (box, flags);

			var monitor_geom = DeepinUtils.get_primary_monitor_geometry (workspace.get_screen ());
			float scale = box.get_width () != 0 ? box.get_width () / (float) monitor_geom.width : 0.5f;

			// calculate monitor width height ratio
			float monitor_whr = (float) monitor_geom.height / monitor_geom.width;

			// alocate workspace clone
			var thumb_box = ActorBox ();
			float thumb_width = box.get_width ();
			float thumb_height = thumb_width * monitor_whr;
			thumb_box.set_size (thumb_width, thumb_height);
			thumb_box.set_origin (0, 0);
			workspace_clone.allocate (thumb_box, flags);
			workspace_shadow.allocate (thumb_box, flags);

 			// scale background and window conatiner
			background.scale_x = scale;
			background.scale_y = scale;
			window_container.scale_x = scale;
			window_container.scale_y = scale;

			var thumb_shape_box = ActorBox ();
			thumb_shape_box.set_size (thumb_width + SHAPE_PADDING * 2,
									  thumb_height + SHAPE_PADDING * 2);
			thumb_shape_box.set_origin ((box.get_width () - thumb_shape_box.get_width ()) / 2,
										-SHAPE_PADDING);
			thumb_shape.allocate (thumb_shape_box, flags);

			var close_box = ActorBox ();
			close_box.set_size (close_button.width, close_button.height);
			close_box.set_origin (box.get_width () - close_box.get_width () * 0.5f,
								  -close_button.height * 0.5f);
			close_button.allocate (close_box, flags);

			var name_shape_box = ActorBox ();
			name_shape_box.set_size (WORKSPACE_NAME_WIDTH + SHAPE_PADDING * 2,
									 WORKSPACE_NAME_HEIGHT + SHAPE_PADDING * 2);
			name_shape_box.set_origin ((box.get_width () - name_shape_box.get_width ()) / 2,
									   thumb_box.y2 + WORKSPACE_NAME_DISTANCE);
			name_shape.allocate (name_shape_box, flags);

			var name_box = ActorBox ();
			name_box.set_size (Math.fminf (workspace_name.width, WORKSPACE_NAME_WIDTH), workspace_name.height);
			name_box.set_origin ((box.get_width () - name_box.get_width ()) / 2,
								 name_shape_box.y1 + (name_shape_box.get_height () -
													  name_box.get_height ()) / 2);
			workspace_name.allocate (name_box, flags);

			// update layout for workspace name field.
			var name_layout = workspace_name.layout_manager as BoxLayout;
			if (workspace_name_text.text.length > 0 || workspace_name_text.editable) {
				name_layout.spacing = WORKSPACE_NAME_SPACING;
			} else {
				name_layout.spacing = 0;
			}
		}
	}
}