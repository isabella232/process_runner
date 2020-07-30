// Copyright 2020 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show Encoding;
import 'dart:io' show Directory, Platform, stdout, SystemEncoding;

import 'package:async/async.dart' show StreamGroup;

import 'process_runner.dart';

/// A class that represents a job to be done by a [ProcessPool].
///
/// Create a list of these to pass to [ProcessPool.startWorkers] or
/// [ProcessPool.runToCompletion].
class WorkerJob {
  WorkerJob(
    this.command, {
    String name,
    this.workingDirectory,
    this.printOutput = false,
    this.stdin,
    this.stdinRaw,
  }) : name = name ?? command.join(' ');

  /// The name of the job.
  ///
  /// Defaults to the args joined by a space.
  final String name;

  /// The name and arguments for the process, including the command name as
  /// command[0].
  final List<String> command;

  /// The working directory that the command should be executed in.
  final Directory workingDirectory;

  /// If set, the stream to read the stdin for this process from.
  ///
  /// It will be encoded using the [ProcessPool.encoding] before being sent to
  /// the process.
  ///
  /// If both [stdin] and [stdinRaw] are set, only [stdinRaw] will be used.
  final Stream<String> stdin;

  /// If set, the stream to read the raw stdin for this process from.
  ///
  /// It will be used directly, and not encoded (as [stdin] would be).
  ///
  /// If both [stdin] and [stdinRaw] are set, only [stdinRaw] will be used.
  final Stream<List<int>> stdinRaw;

  /// Whether or not this command should print it's stdout when it runs.
  final bool printOutput;

  /// Once the job is complete, this contains the result of the job.
  ///
  /// The [stderr], [stdout], and [output] accessors will decode their raw
  /// equivalents using the [ProcessRuner.decoder] that is set on the process
  /// runner for the pool that ran this job.
  ///
  /// If no process runner is supplied to the pool, then the decoder will be the
  /// same as the [ProcessPool.encoding] that was set on the pool.
  ProcessRunnerResult result;

  @override
  String toString() {
    return command.join(' ');
  }
}

/// The type of the reporting function for [ProcessPool.printReport].
typedef ProcessPoolProgressReporter = void Function(
  int totalJobs,
  int completed,
  int inProgress,
  int pending,
  int failed,
);

/// A pool of worker processes that will keep [numWorkers] busy until all of the
/// (presumably single-threaded) processes are finished.
class ProcessPool {
  ProcessPool({
    int numWorkers,
    ProcessRunner processRunner,
    this.printReport = defaultPrintReport,
    this.encoding = const SystemEncoding(),
  })  : processRunner = processRunner ?? ProcessRunner(decoder: encoding),
        numWorkers = numWorkers ?? Platform.numberOfProcessors;

  /// A function to be called periodically to update the progress on the pool.
  ///
  /// May be set to null if no progress report is desired.
  ///
  /// Defaults to [defaultProgressReport], which prints the progress report to
  /// stdout.
  final ProcessPoolProgressReporter printReport;

  /// The decoder to use for decoding the stdout, stderr, and output of a
  /// process, and encoding the stdin from the job.
  ///
  /// Defaults to an instance of [SystemEncoding].
  final Encoding encoding;

  /// The process runner to use when running the jobs in the pool.
  ///
  /// Setting this allows for configuration of the process runnner.
  ///
  /// Be default, a default-constructed [ProcessRunner] is used.
  ///
  /// Must not be null.
  final ProcessRunner processRunner;

  /// The number of workers to use for this pool.
  ///
  /// Defaults to the number of processors the machine has.
  final int numWorkers;

  /// Returns the number of jobs currently in progress.
  int get inProgressJobs => _inProgressJobs;
  int _inProgressJobs = 0;

  /// Returns the number of jobs that have been completed
  int get completedJobs => _completedJobs.length;

  /// Returns the number of jobs that are pending.
  int get pendingJobs => _pendingJobs.length;

  /// Returns the number of jobs that have failed so far.
  int get failedJobs => _failedJobs.length;

  /// Returns the total number of jobs that have been given to this pool.
  int get totalJobs =>
      _completedJobs.length + _inProgressJobs + _pendingJobs.length + _failedJobs.length;

  final List<WorkerJob> _pendingJobs = <WorkerJob>[];
  final List<WorkerJob> _failedJobs = <WorkerJob>[];
  final List<WorkerJob> _completedJobs = <WorkerJob>[];

  void _printReportIfNeeded() {
    if (printReport == null) {
      return;
    }
    printReport?.call(
        totalJobs, _completedJobs.length, _inProgressJobs, _pendingJobs.length, _failedJobs.length);
  }

  /// The default report printing function, if one is not supplied.
  static void defaultPrintReport(
    int total,
    int completed,
    int inProgress,
    int pending,
    int failed,
  ) {
    final String percent = total == 0 ? '100' : ((100 * completed) ~/ total).toString().padLeft(3);
    final String completedStr = completed.toString().padLeft(3);
    final String totalStr = total.toString().padRight(3);
    final String inProgressStr = inProgress.toString().padLeft(2);
    final String pendingStr = pending.toString().padLeft(3);
    final String failedStr = failed.toString().padLeft(3);

    stdout.write(
        'Jobs: $percent% done, $completedStr/$totalStr completed, $inProgressStr in progress, $pendingStr pending, $failedStr failed.    \r');
  }

  Future<WorkerJob> _performJob(WorkerJob job) async {
    try {
      job.result = null;
      job.result = await processRunner.runProcess(
        job.command,
        workingDirectory: job.workingDirectory,
        printOutput: job.printOutput,
        stdin: job.stdinRaw ?? (job.stdin != null ? encoding.encoder.bind(job.stdin) : null),
      );
      _completedJobs.add(job);
    } on ProcessRunnerException catch (e) {
      print('\nJob $job failed: $e');
      _failedJobs.add(job);
    } finally {
      _inProgressJobs--;
      _printReportIfNeeded();
    }
    return job;
  }

  Stream<WorkerJob> _startWorker() async* {
    while (_pendingJobs.isNotEmpty) {
      final WorkerJob newJob = _pendingJobs.removeAt(0);
      _inProgressJobs++;
      yield await _performJob(newJob);
    }
  }

  /// Runs all of the jobs to completion, and returns a list of completed jobs
  /// when all have been completed.
  ///
  /// To listen to jobs as they are completed, use [startWorkers] instead.
  Future<List<WorkerJob>> runToCompletion(List<WorkerJob> jobs) async {
    final List<WorkerJob> results = <WorkerJob>[];
    await startWorkers(jobs).forEach(results.add);
    return results;
  }

  /// Runs the `jobs` in parallel, with at most [numWorkers] jobs running
  /// simultaneously.
  ///
  /// Returns the the jobs in a [Stream] as they are completed.
  Stream<WorkerJob> startWorkers(List<WorkerJob> jobs) async* {
    assert(_inProgressJobs == 0);
    _failedJobs.clear();
    _completedJobs.clear();
    if (jobs.isEmpty) {
      return;
    }
    _pendingJobs.addAll(jobs);
    final List<Stream<WorkerJob>> streams = <Stream<WorkerJob>>[];
    for (int i = 0; i < numWorkers; ++i) {
      if (_pendingJobs.isEmpty) {
        break;
      }
      streams.add(_startWorker());
    }
    await for (final WorkerJob job in StreamGroup.merge<WorkerJob>(streams)) {
      yield job;
    }
    assert(_inProgressJobs == 0);
    assert(_pendingJobs.isEmpty);
    return;
  }
}