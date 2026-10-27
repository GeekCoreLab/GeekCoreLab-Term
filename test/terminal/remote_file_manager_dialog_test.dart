import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_manager_dialog.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

void main() {
  testWidgets('shows the two directory panes side by side on desktop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('双栏文件管理'), findsOneWidget);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('远端文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches panes on a compact viewport without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('远端文件'), findsOneWidget);
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();

    expect(find.text('本地文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp() => MaterialApp(
  home: Scaffold(
    body: RemoteFileManagerDialog(
      client: _FakeSshClient(),
      sessionTitle: '测试会话',
      initialRemotePath: '/home/test',
      protocol: RemoteTransferProtocol.sftp,
      onDirectoryChanged: (_) {},
      onProtocolChanged: (_) {},
      onQueueUploads: (_, _, _) async {},
      onQueueDownload: (_, _, _, _) async {},
      onMessage: (_, {isError}) {},
    ),
  ),
);

class _FakeSshClient extends Fake implements SSHClient {
  @override
  Future<SftpClient> sftp() async => _FakeSftpClient();
}

class _FakeSftpClient extends Fake implements SftpClient {
  @override
  Future<String> absolute(String path) async =>
      path.startsWith('/') ? path : '/home/test/$path';

  @override
  Future<List<SftpName>> listdir(String path) async => const [];

  @override
  Future<void> close() async {}
}
