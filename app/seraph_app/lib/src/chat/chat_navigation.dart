import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';

void openChatCitation(ChatCitation citation) {
  if (!citation.isNavigable) {
    return;
  }
  final path = Uri.encodeQueryComponent(citation.viewerPath);
  Get.toNamed('${FileViewerView.routeName}?path=$path');
}
