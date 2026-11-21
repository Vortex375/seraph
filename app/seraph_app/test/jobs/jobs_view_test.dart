import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/jobs/job_models.dart';
import 'package:seraph_app/src/jobs/jobs_service.dart';
import 'package:seraph_app/src/jobs/jobs_view.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

void main() {
  late _FakeJobsService service;
  late _FakeLoginController login;

  setUp(() {
    Get.testMode = true;
    Get.reset();
    login = _FakeLoginController()..isSpaceAdmin.value = true;
    service = _FakeJobsService(login);
    Get.put<ShareController>(_FakeShareController());
    Get.put<LoginController>(login);
    Get.put<JobsService>(service);
  });

  tearDown(Get.reset);

  Future<void> pumpView(WidgetTester tester) async {
    await tester.pumpWidget(GetMaterialApp(
      home: const JobsView(),
      getPages: [
        GetPage(
            name: '/other', page: () => const Scaffold(body: Text('other'))),
      ],
    ));
    await tester.pump();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(GetMaterialApp(
      home: Builder(
        builder: (c) =>
            Scaffold(appBar: seraphAppBar(c, routeName: '/gallery')),
      ),
    ));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('nav entry hidden for non-admin', (tester) async {
    login.isSpaceAdmin.value = false;
    await openMenu(tester);
    expect(find.text('Jobs'), findsNothing);
  });

  testWidgets('nav entry shown for admin', (tester) async {
    await openMenu(tester);
    expect(find.text('Jobs'), findsOneWidget);
  });

  testWidgets('bars: determinate, indeterminate, none; waiting; stalled',
      (tester) async {
    final now = DateTime.now();
    service.jobs = [
      _job('batch', state: 'running', done: 5, total: 20, time: now),
      _job('unknown', state: 'running', time: now),
      _job('finished', state: 'completed', done: 20, total: 20, time: now),
      _job('queue', state: 'idle', pending: 1234, time: now),
      _job('stuck',
          state: 'running',
          done: 1,
          total: 2,
          time: now.subtract(const Duration(minutes: 3))),
    ];
    await pumpView(tester);

    LinearProgressIndicator bar(String desc) => tester.widget(find.descendant(
        of: find.widgetWithText(Card, desc),
        matching: find.byType(LinearProgressIndicator)));
    expect(bar('batch').value, 0.25);
    expect(bar('unknown').value, isNull);
    expect(
        find.descendant(
            of: find.widgetWithText(Card, 'finished'),
            matching: find.byType(LinearProgressIndicator)),
        findsNothing);
    expect(
        find.descendant(
            of: find.widgetWithText(Card, 'queue'),
            matching: find.byType(LinearProgressIndicator)),
        findsNothing);
    expect(find.textContaining('1,234 waiting'), findsOneWidget);
    expect(find.text('stalled'), findsOneWidget);
    expect(
        find.descendant(
            of: find.widgetWithText(Card, 'stuck'),
            matching: find.text('stalled')),
        findsOneWidget);
  });

  testWidgets('403 and other errors show messages', (tester) async {
    service.error = DioException(
      requestOptions: RequestOptions(path: '/api/jobs'),
      response: Response(
          requestOptions: RequestOptions(path: '/api/jobs'), statusCode: 403),
    );
    await pumpView(tester);
    expect(find.text('Only space admins can see jobs'), findsOneWidget);

    service.error =
        DioException(requestOptions: RequestOptions(path: '/api/jobs'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('Could not load jobs'), findsOneWidget);
  });

  testWidgets('polls every 3 s and stops after leaving the screen',
      (tester) async {
    await pumpView(tester);
    expect(service.calls, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(service.calls, 2);

    Get.offNamed('/other');
    await tester.pumpAndSettle();
    expect(find.text('other'), findsOneWidget);
    final before = service.calls;
    await tester.pump(const Duration(seconds: 12));
    expect(service.calls, before);
  });

  test('sortJobs: running, failed, rest; newest first', () {
    final t = DateTime(2026, 1, 1);
    final sorted = sortJobs([
      _job('old-done',
          state: 'completed', time: t.add(const Duration(hours: 3))),
      _job('failed', state: 'failed', time: t),
      _job('run-old', state: 'running', time: t),
      _job('run-new', state: 'running', time: t.add(const Duration(hours: 1))),
    ]);
    expect(sorted.map((j) => j.description),
        ['run-new', 'run-old', 'failed', 'old-done']);
  });
}

Job _job(String desc,
        {required String state,
        int? done,
        int? total,
        int? pending,
        required DateTime time}) =>
    Job(
      key: desc,
      description: desc,
      statusMessage: '',
      state: state,
      time: time,
      done: done,
      total: total,
      pending: pending,
    );

class _FakeJobsService extends JobsService {
  _FakeJobsService(LoginController login)
      : super(_FakeSettingsController(), login);

  List<Job> jobs = [];
  Object? error;
  int calls = 0;

  @override
  Future<List<Job>> list() async {
    calls++;
    if (error != null) throw error!;
    return jobs;
  }
}

class _FakeSettingsController extends GetxController
    implements SettingsController {
  final Rx<String> _serverUrl = 'https://seraph.test'.obs;

  @override
  Rx<String> get serverUrl => _serverUrl;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLoginController extends GetxController implements LoginController {
  final Rx<bool> _isSpaceAdmin = false.obs;
  final Rx<bool> _isInitialized = true.obs;
  final Rx<OidcUser?> _currentUser = Rx<OidcUser?>(null);

  @override
  Rx<bool> get isSpaceAdmin => _isSpaceAdmin;

  @override
  Rx<bool> get isInitialized => _isInitialized;

  @override
  Rx<OidcUser?> get currentUser => _currentUser;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeShareController extends GetxController implements ShareController {
  @override
  final RxBool shareMode = false.obs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
