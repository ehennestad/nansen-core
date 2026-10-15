classdef TasksTest < matlab.unittest.TestCase
%TasksTest The task queue: submitting, running, cancelling, retrying, recovering

    properties
        Project
        Queue
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            folder = fixture.Folder;
            repo = fileparts(fileparts(fileparts(mfilename("fullpath"))));
            copyfile(fullfile(repo, "testdata", "entities-dataset.dsm.json"), fullfile(folder, "dataset.dsm.json"));
            for path = ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-002/movie.tif"]
                target = fullfile(folder, "data", "raw", path);
                mkdir(fileparts(target));
                nansen.internal.writeText(target, repmat('x', 1, 10));
            end
            project = nansen.Project.create(folder, "Pilot", Dataset="dataset.dsm.json");
            project.addModule("core");
            project.addEntityType("subject");
            project.addEntityType("session", Fragments="core.notes");
            project.scan();
            project.sync("session");
            testCase.Project = project;
            testCase.Queue = nansen.TaskQueue(project);
        end
    end

    methods
        function entities = sessions(testCase)
            entities = testCase.Project.entities("session");
        end
    end

    methods (Test)
        function submitResolvesOptionsAndQueues(testCase)
            task = testCase.Queue.submit("core.wait", testCase.sessions(), Options=struct("seconds", 0));
            testCase.verifyEqual(string(task.status), "queued");
            testCase.verifyEqual(task.options.values.steps, 10);
            tasks = testCase.Queue.list();
            testCase.verifyEqual(string(tasks{1}.id), string(task.id));
            testCase.verifyError(@() testCase.Queue.submit("core.wait", testCase.sessions(), ...
                Options=struct("seconds", "soon")), "nansen:InvalidOptions");
        end

        function tasksKeepTheOrderTheyWereQueuedIn(testCase)
            % Many in one millisecond: their creation times still grow, so the random ids do not decide
            sessions = testCase.sessions();
            ids = strings(1, 20);
            for i = 1:20
                task = testCase.Queue.submit("core.wait", sessions(1), Options=struct("seconds", 0));
                ids(i) = string(task.id);
            end
            listed = cellfun(@(t) string(t.id), testCase.Queue.list());
            testCase.verifyEqual(listed, ids);
            testCase.verifyEqual(string(testCase.Queue.nextTask().id), ids(1));
        end

        function queuedTasksAreHeldChangedAndReordered(testCase)
            sessions = testCase.sessions();
            ids = strings(1, 3);
            for i = 1:3
                task = testCase.Queue.submit("core.wait", sessions(mod(i - 1, numel(sessions)) + 1), ...
                    Options=struct("seconds", 0));   % the fixture has two sessions
                ids(i) = string(task.id);
            end
            testCase.Queue.hold(ids(1));
            testCase.verifyEqual(string(testCase.Queue.nextTask().id), ids(2));
            order = testCase.Queue.reorder(ids(3));
            testCase.verifyEqual(cellfun(@(t) string(t.id), order), ids([3, 1, 2]));
            changed = testCase.Queue.update(ids(3), Options=struct("seconds", 0, "message", "changed"));
            testCase.verifyEqual(string(changed.options.values.message), "changed");
            testCase.verifyEqual(string(testCase.Queue.runNext().id), ids(3));
            testCase.verifyEqual(string(testCase.Queue.runNext().id), ids(2));   % the first is on hold
            testCase.verifyEmpty(testCase.Queue.runNext());
            testCase.Queue.hold(ids(1), false);
            testCase.verifyEqual(string(testCase.Queue.runNext().id), ids(1));
            testCase.verifyError(@() testCase.Queue.hold(ids(1)), "nansen:TaskNotQueued");
        end

        function runNextCompletesWithLogAndResult(testCase)
            task = testCase.Queue.submit("core.wait", testCase.sessions(), Options=struct("seconds", 0, "steps", 2));
            done = testCase.Queue.runNext();
            testCase.verifyEqual(string(done.status), "completed");
            testCase.verifyEqual(done.progress, 1);
            testCase.verifyTrue(contains(testCase.Queue.log(string(task.id)), "completed"));
            testCase.verifyEmpty(testCase.Queue.runNext());
        end

        function theBackgroundWorkerRunsQueuedTasks(testCase)
            % start(): tasks run on backgroundPool, polled by a timer, while MATLAB is free
            task = testCase.Queue.submit("core.wait", testCase.sessions(), Options=struct("seconds", 0));
            testCase.Queue.start(0.1);
            stopper = onCleanup(@() testCase.Queue.stop());
            testCase.verifyTrue(testCase.Queue.isRunning());
            deadline = tic;
            while ~ismember(string(testCase.Queue.get(string(task.id)).status), ["completed", "failed"]) && toc(deadline) < 120
                pause(0.2);   % the timer runs while MATLAB waits
            end
            done = testCase.Queue.get(string(task.id));
            testCase.verifyEqual(string(done.status), "completed", jsonencode(nansen.internal.getField(done, "error", struct())));
            testCase.Queue.stop();
            testCase.verifyFalse(testCase.Queue.isRunning());
            testCase.Queue.Worker = "process";
            if ~nansen.TaskQueue.hasProcessPools()
                testCase.verifyError(@() testCase.Queue.start(), "nansen:DependencyMissing");
            end
        end

        function failureIsRecordedAndRetryMakesANewTask(testCase)
            sessions = testCase.sessions();
            task = testCase.Queue.submit("core.wait", sessions(1), Options=struct("seconds", 0, "steps", 1, "fail", true));
            failed = testCase.Queue.runNext();
            testCase.verifyEqual(string(failed.status), "failed");
            testCase.verifyEqual(string(failed.error.message), "failed on purpose");
            again = testCase.Queue.retry(string(task.id));
            testCase.verifyNotEqual(string(again.id), string(task.id));
            testCase.verifyEqual(string(again.status), "queued");
        end

        function cancelQueuedTask(testCase)
            task = testCase.Queue.submit("core.wait", testCase.sessions(), Options=struct("seconds", 0));
            cancelled = testCase.Queue.cancel(string(task.id));
            testCase.verifyEqual(string(cancelled.status), "cancelled");
            testCase.verifyEmpty(testCase.Queue.runNext());
        end

        function cancelFileStopsARunningTask(testCase)
            task = testCase.Queue.submit("core.wait", testCase.sessions(), Options=struct("seconds", 0, "steps", 3));
            nansen.internal.writeText(testCase.Queue.cancelPath(string(task.id)), "now");
            done = testCase.Queue.runNext();
            testCase.verifyEqual(string(done.status), "cancelled");
            testCase.verifyFalse(isfile(testCase.Queue.cancelPath(string(task.id))));
        end

        function recoverMarksInterruptedTasksFailed(testCase)
            sessions = testCase.sessions();
            task = testCase.Queue.submit("core.wait", sessions(1));
            task.status = 'running';
            testCase.Queue.save(task)
            testCase.verifyEqual(testCase.Queue.recover(), string(task.id));
            testCase.verifyEqual(string(testCase.Queue.get(string(task.id)).status), "failed");
        end

        function removeAndClear(testCase)
            sessions = testCase.sessions();
            a = testCase.Queue.submit("core.wait", sessions(1), Options=struct("seconds", 0, "steps", 1));
            testCase.Queue.submit("core.wait", sessions(1), Options=struct("seconds", 0, "steps", 1));
            testCase.Queue.runNext();
            testCase.Queue.remove(string(a.id));
            testCase.verifyEqual(numel(testCase.Queue.list()), 1);
            testCase.Queue.runNext();
            testCase.verifyEqual(testCase.Queue.clear(), 1);
            testCase.verifyEmpty(testCase.Queue.list());
        end

        function tasksForAnotherLanguageAreLeftAlone(testCase)
            sessions = testCase.sessions();
            testCase.Queue.submit("core.wait", sessions(1), Language="python");
            testCase.verifyEmpty(testCase.Queue.runNext());
        end

        function pipelineRunsStepsInOrderPerEntity(testCase)
            tasks = testCase.Queue.submitPipeline("core.inspect", testCase.sessions());
            testCase.verifyEqual(numel(tasks), 4);
            testCase.verifyEqual(string(tasks{2}.after), string(tasks{1}.id));
            testCase.verifyEqual(tasks{2}.pipeline.step, 1);
            testCase.verifyEqual(string(tasks{2}.options.values.message), "pausing");
            done = testCase.Queue.runAll();
            testCase.verifyEqual(cellfun(@(t) string(t.status), done), repmat("completed", 1, 4));
            ids = cellfun(@(t) string(t.id), done);
            testCase.verifyLessThan(find(ids == string(tasks{1}.id)), find(ids == string(tasks{2}.id)));
        end

        function pipelineStepAfterAFailureIsCancelled(testCase)
            sessions = testCase.sessions();
            tasks = testCase.Queue.submitPipeline("core.inspect", sessions(1));
            testCase.Queue.cancel(string(tasks{1}.id));
            testCase.verifyEmpty(testCase.Queue.runNext());
            second = testCase.Queue.get(string(tasks{2}.id));
            testCase.verifyEqual(string(second.status), "cancelled");
        end

        function taskWrittenByEitherLanguageReadsBack(testCase)
            task = testCase.Queue.submit("core.export_keys", testCase.sessions());
            done = nansen.runTask(testCase.Project.Folder, string(task.id));
            testCase.verifyEqual(string(done.status), "completed");
            testCase.verifyEqual(done.result.count, 2);
        end
    end
end
