import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';


import '../settings/settings_view.dart';
import 'file_item.dart';

class MyAppState extends ChangeNotifier {
  var current = 'foo';
}


/// Displays a list of SampleItems.
class FileBrowserListView extends StatelessWidget {
  const FileBrowserListView({
    super.key,
    this.items = const [FileItem(1), FileItem(2)],
  });

  static const routeName = '/';

  final List<FileItem> items;

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: seraphAppBar(context, 'Cloud Files', routeName, [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              GoRouter.of(context).push(SettingsView.routeName);
            },
          ),
        ]),

      // To work with lists that may contain a large number of items, it’s best
      // to use the ListView.builder constructor.
      //
      // In contrast to the default ListView constructor, which requires
      // building all Widgets up front, the ListView.builder constructor lazily
      // builds Widgets as they’re scrolled into view.
      body: ListView.builder(
        // Providing a restorationId allows the ListView to restore the
        // scroll position when a user leaves and returns to the app after it
        // has been killed while running in the background.
        restorationId: 'sampleItemListView',
        itemCount: items.length,
        itemBuilder: (BuildContext context, int index) {
          final item = items[index];

          return ListTile(
            title: Text('SampleItem ${item.id}'),
            leading: const CircleAvatar(
              // Display the Flutter Logo image asset.
              foregroundImage: AssetImage('assets/images/flutter_logo.png'),
            ),
            onTap: () {
              // Navigate to the details page. If the user leaves and returns to
              // the app after it has been killed while running in the
              // background, the navigation stack is restored.
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text("Item Selected"),
              ));
            }
          );
        },
      ),
    );
  }
}
