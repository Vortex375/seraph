class Job {
  const Job({
    required this.key,
    required this.description,
    required this.statusMessage,
    required this.state,
    required this.time,
    this.done,
    this.total,
    this.pending,
  });

  factory Job.fromJson(Map<String, dynamic> json) {
    // negative or missing numbers mean "unknown"
    int? known(Object? v) => v is num && v >= 0 ? v.toInt() : null;
    return Job(
      key: json['key'] as String? ?? '',
      description: json['description'] as String? ?? '',
      statusMessage: json['statusMessage'] as String? ?? '',
      state: json['state'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      done: known(json['done']),
      total: known(json['total']),
      pending: known(json['pending']),
    );
  }

  final String key;
  final String description;
  final String statusMessage;
  final String state;
  final DateTime time;
  final int? done;
  final int? total;
  final int? pending;

  bool get isRunning => state == 'running';
  bool get isFailed => state == 'failed';

  /// Running with no heartbeat for more than two minutes.
  bool isStalled(DateTime now) =>
      isRunning && now.difference(time) > const Duration(minutes: 2);

  /// 0..1 for a determinate bar, null when there is no total.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return ((done ?? 0) / t).clamp(0.0, 1.0);
  }

  bool get showsIndeterminateBar => isRunning && fraction == null;

  /// A finished or idle Job shows no bar, whatever its last counters were.
  bool get showsBar =>
      state != 'completed' &&
      state != 'idle' &&
      (fraction != null || showsIndeterminateBar);
}

/// Running first, then failed, then the rest; newest first within each group.
List<Job> sortJobs(Iterable<Job> jobs) {
  int rank(Job j) => j.isRunning ? 0 : (j.isFailed ? 1 : 2);
  return jobs.toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : b.time.compareTo(a.time);
    });
}

/// 1234 -> "1,234"
String formatCount(int n) => n.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
