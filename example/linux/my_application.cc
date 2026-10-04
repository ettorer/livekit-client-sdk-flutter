#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* vdi_channel;
};

// Screen origin of the Flutter view, in the same coordinates gtk_window_move
// uses. The Dart VDI room adds each video tile's offset to this origin.
static void vdi_method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call, gpointer user_data) {
  (void)channel;
  FlView* view = FL_VIEW(user_data);
  const gchar* name = fl_method_call_get_name(method_call);

  if (g_strcmp0(name, "getViewOrigin") != 0) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    g_autoptr(GError) error = nullptr;
    if (!fl_method_call_respond(method_call, response, &error) && error != nullptr) {
      g_warning("Failed to respond to VDI method call: %s", error->message);
    }
    return;
  }

  GtkWidget* widget = GTK_WIDGET(view);
  gint x = 0;
  gint y = 0;
  gint scale = 1;
  GtkWidget* toplevel = gtk_widget_get_toplevel(widget);

  if (GTK_IS_WINDOW(toplevel)) {
    GdkWindow* gdk_window = gtk_widget_get_window(toplevel);
    if (gdk_window != nullptr) {
      gint origin_x = 0;
      gint origin_y = 0;
      gint rel_x = 0;
      gint rel_y = 0;
      // gdk_window_get_origin already returns application pixels: the X11
      // backend divides root coordinates by the window scale. That is the
      // same space gtk_window_move and gtk_window_resize use, and the same
      // space as Flutter logical pixels (Flutter's device pixel ratio is
      // this scale factor). Do not multiply by the scale here; on a 150%
      // desktop GDK_SCALE is 2 and that would double every tile.
      gdk_window_get_origin(gdk_window, &origin_x, &origin_y);
      scale = gdk_window_get_scale_factor(gdk_window);
      if (scale < 1) {
        scale = 1;
      }
      if (gtk_widget_translate_coordinates(widget, toplevel, 0, 0, &rel_x, &rel_y)) {
        x = origin_x + rel_x;
        y = origin_y + rel_y;
      } else {
        x = origin_x;
        y = origin_y;
      }
    }
  }

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "x", fl_value_new_int(x));
  fl_value_set_string_take(result, "y", fl_value_new_int(y));
  fl_value_set_string_take(result, "scale", fl_value_new_int(scale));
  fl_value_set_string_take(result, "devicePixels", fl_value_new_bool(FALSE));

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, result, &error) && error != nullptr) {
    g_warning("Failed to send VDI view origin: %s", error->message);
  }
}

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "livekit_client_example");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "livekit_client_example");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_clear_object(&self->vdi_channel);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->vdi_channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                            "livekit_example/vdi_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->vdi_channel, vdi_method_call_cb, g_object_ref(view),
                                            g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->vdi_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) { self->vdi_channel = nullptr; }

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
