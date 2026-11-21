import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/jobs/job_models.dart';
import 'package:seraph_app/src/jobs/jobs_service.dart';

class JobsView extends StatefulWidget {
  const JobsView({super.key});

  static const routeName = '/jobs';

  @override
  State<JobsView> createState() => _JobsViewState();
}

class _JobsViewState extends State<JobsView> {
  final JobsService _service = Get.find();
  Timer? _timer;
  List<Job>? _jobs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jobs = sortJobs(await _service.list());
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is DioException && e.response?.statusCode == 403
            ? 'Only space admins can see jobs'
            : 'Could not load jobs. Pull down to retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _jobs;
    final Widget body;
    if (_error != null) {
      body = _scrollable(Center(child: Text(_error!)));
    } else if (jobs == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (jobs.isEmpty) {
      body = _scrollable(const Center(child: Text('No background jobs')));
    } else {
      final now = DateTime.now();
      body = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: jobs.length,
        itemBuilder: (context, i) => _JobTile(job: jobs[i], now: now),
      );
    }

    return Scaffold(
      appBar: seraphAppBar(
        context,
        name: 'Background jobs',
        routeName: JobsView.routeName,
      ),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }

  // RefreshIndicator needs a scrollable child, also for messages
  Widget _scrollable(Widget child) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(height: c.maxHeight, child: child),
        ),
      );
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.now});

  final Job job;
  final DateTime now;

  static String _ago(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds} s';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = job.pending;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(job.description,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (job.isStalled(now))
                Chip(
                  label: const Text('stalled'),
                  backgroundColor: scheme.errorContainer,
                ),
            ]),
            if (job.statusMessage.isNotEmpty)
              Text(
                job.statusMessage,
                style: job.isFailed ? TextStyle(color: scheme.error) : null,
              ),
            if (job.showsBar)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(value: job.fraction),
              ),
            const SizedBox(height: 4),
            Text(
              [
                if (pending != null && pending > 0)
                  '${formatCount(pending)} waiting',
                'updated ${_ago(now.difference(job.time))} ago',
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
