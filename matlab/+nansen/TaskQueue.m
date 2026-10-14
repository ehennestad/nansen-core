classdef TaskQueue < handle
%TaskQueue The tasks of one project: methods queued on entities, kept as nansen.task documents
%
%   queue = nansen.TaskQueue(project) works on <project>/tasks. A task file
%   describes everything a worker needs, so it can run in this session, on
%   a background worker, or in Python. While a task runs its worker owns the
%   file; anyone else asks it to stop by creating tasks/<id>.cancel.
%
%   OnEvent(kind, data) is called with kind "task" (a task changed) or "log".
%   runNext/runAll run tasks in this session; start() runs them on
%   backgroundPool, polled by a timer, until stop().

    properties
        OnEvent = []
    end

    properties (SetAccess = private)
        Project
        Folder (1,1) string
    end

    properties (Access = private)
        Timer = []
        Future = []
        FutureTaskId (1,1) string = ""
    end

    methods
        function obj = TaskQueue(project, options)
            arguments
                project
                options.OnEvent = []
            end
            obj.Project = project;
            obj.Folder = string(fullfile(project.Folder, "tasks"));
            obj.OnEvent = options.OnEvent;
        end

        function delete(obj)
            obj.stop();
        end

        % -- documents --------------------------------------------------------------------

        function path = path(obj, taskId)
            path = string(fullfile(obj.Folder, taskId + ".task.nansen.json"));
        end

        function path = logPath(obj, taskId)
            path = string(fullfile(obj.Folder, taskId + ".log"));
        end

        function path = cancelPath(obj, taskId)
            path = string(fullfile(obj.Folder, taskId + ".cancel"));
        end

        function path = claimPath(obj, taskId)
            path = string(fullfile(obj.Folder, taskId + ".claim"));
        end

        function tf = claim(obj, taskId)
            %claim Take a queued task for this worker; the claim is a folder, which two workers cannot both create
            [~, ~, messageId] = mkdir(obj.claimPath(taskId));
            tf = isempty(messageId);
        end

        function release(obj, taskId)
            if isfolder(obj.claimPath(taskId))
                rmdir(obj.claimPath(taskId));
            end
        end

        function task = get(obj, taskId)
            path = obj.path(taskId);
            if ~isfile(path)
                nansen.internal.throwError("unknown-task", "no task '%s'", taskId)
            end
            task = nansen.readDocument(path, ExpectedType="nansen.task");
        end

        function tasks = list(obj, status)
            %list Tasks in the order they were created: a cell row of structs
            arguments
                obj
                status (1,1) string = ""
            end
            tasks = {};
            if ~isfolder(obj.Folder)
                return
            end
            listing = dir(fullfile(obj.Folder, "*.task.nansen.json"));
            for i = 1:numel(listing)
                try
                    tasks{end + 1} = nansen.readDocument(fullfile(obj.Folder, listing(i).name), ...
                        ExpectedType="nansen.task"); %#ok<AGROW>
                catch err
                    if ~isa(err, "nansen.NansenError")
                        rethrow(err)
                    end
                end
            end
            if isempty(tasks)
                return
            end
            order = cellfun(@(t) string(t.createdAt) + " " + string(t.id), tasks);
            [~, sorting] = sort(order);
            tasks = tasks(sorting);
            if status ~= ""
                tasks = tasks(cellfun(@(t) string(t.status) == status, tasks));
            end
        end

        function text = log(obj, taskId)
            text = "";
            if isfile(obj.logPath(taskId))
                text = string(nansen.internal.readText(obj.logPath(taskId)));
            end
        end

        function save(obj, task)
            %save Validate and write a task document atomically, then tell OnEvent
            if ~isfolder(obj.Folder)
                mkdir(obj.Folder);
            end
            task = nansen.checkDocument(task, ExpectedType="nansen.task");
            path = obj.path(string(task.id));
            temporary = path + "." + string(feature("getpid")) + ".tmp";
            nansen.internal.writeJson(temporary, task)
            movefile(temporary, path, "f");
            obj.emit("task", task)
        end

        function emit(obj, kind, data)
            if ~isempty(obj.OnEvent)
                obj.OnEvent(kind, data);
            end
        end

        % -- queueing ---------------------------------------------------------------------

        function task = submit(obj, methodId, entities, options)
            %submit Queue a method on a cell array of entities; options are resolved and validated now
            arguments
                obj
                methodId (1,1) string
                entities (1,:) cell
                options.Options = struct()
                options.Preset (1,1) string = ""
                options.Language (1,1) string = ""
            end
            method = obj.Project.method(methodId);
            if ~method.Queueable
                nansen.internal.throwError("not-queueable", "method '%s' cannot run in the background", methodId)
            end
            if isempty(entities)
                nansen.internal.throwError("no-entities", "a task needs at least one entity")
            end
            for i = 1:numel(entities)
                if ~method.appliesTo(entities{i}.EntityType)
                    nansen.internal.throwError("wrong-entity-type", "%s runs on %s", method.Id, method.EntityType)
                end
            end
            task = obj.makeTask(method, entities, options.Options, options.Preset, options.Language);
            obj.save(task)
        end

        function tasks = submitPipeline(obj, pipelineId, entities, options)
            %submitPipeline Queue a pipeline: per entity, one task per step, each waiting for the step before
            arguments
                obj
                pipelineId (1,1) string
                entities (1,:) cell
                options.Language (1,1) string = ""
            end
            pipeline = obj.Project.pipeline(pipelineId);
            if isempty(entities)
                nansen.internal.throwError("no-entities", "a pipeline needs at least one entity")
            end
            steps = nansen.internal.asCellOfStructs(pipeline.steps);
            methods = cell(1, numel(steps));
            for s = 1:numel(steps)
                methods{s} = obj.Project.method(string(steps{s}.method));
                for i = 1:numel(entities)
                    if ~methods{s}.appliesTo(entities{i}.EntityType)
                        nansen.internal.throwError("wrong-entity-type", "%s runs on %s", methods{s}.Id, methods{s}.EntityType)
                    end
                end
            end
            tasks = {};
            for i = 1:numel(entities)
                run = nansen.internal.uuid4();
                previous = "";
                for s = 1:numel(steps)
                    step = steps{s};
                    info = struct("id", char(string(pipeline.id)), "run", char(run), "step", s - 1, ...
                        "steps", numel(steps), "title", char(nansen.internal.getField(step, "title", methods{s}.Title)));
                    task = obj.makeTask(methods{s}, entities(i), nansen.internal.getField(step, "options", struct()), ...
                        string(nansen.internal.getField(step, "preset", "")), options.Language, previous, info);
                    tasks{end + 1} = task; %#ok<AGROW>
                    previous = string(task.id);
                end
            end
            for i = 1:numel(tasks)
                obj.save(tasks{i})
            end
        end

        function task = makeTask(obj, method, entities, values, preset, language, after, pipeline)
            %makeTask A queued task document; options are resolved and validated now
            arguments
                obj
                method
                entities (1,:) cell
                values = struct()
                preset (1,1) string = ""
                language (1,1) string = ""
                after (1,1) string = ""
                pipeline = []
            end
            base = struct();
            if preset ~= ""
                base = obj.Project.preset(method.Id, preset);
            end
            if isempty(values)
                values = struct();
            end
            resolved = method.resolveOptions(nansen.internal.mergeStructs(base, values));
            references = cellfun(@(e) struct("entityType", char(e.EntityType), "key", e.Key), entities, UniformOutput=false);
            optionsEntry = struct("values", resolved);
            if preset ~= ""
                optionsEntry.preset = char(preset);
            end
            entry = nansen.internal.schemaEntry("nansen.task");
            task = struct("schemaType", 'nansen.task', "schemaVersion", char(entry.version), ...
                "id", char(nansen.internal.uuid4()), ...
                "method", struct("id", char(method.Id), "version", char(method.Version)), ...
                "entities", {references}, "options", optionsEntry, "status", 'queued', ...
                "createdAt", char(nansen.internal.timestamp()), "progress", 0);
            if language ~= ""
                task.language = char(language);
            end
            if after ~= ""
                task.after = {char(after)};
            end
            if ~isempty(pipeline)
                task.pipeline = pipeline;
            end
        end

        function task = cancel(obj, taskId)
            %cancel Cancel a queued task now; ask a running task to stop at its next check
            task = obj.get(taskId);
            if string(task.status) == "queued"
                task.status = 'cancelled';
                task.finishedAt = char(nansen.internal.timestamp());
                obj.save(task)
            elseif string(task.status) == "running"
                nansen.internal.writeText(obj.cancelPath(taskId), nansen.internal.timestamp());
            end
        end

        function task = retry(obj, taskId)
            %retry Queue a finished task again, as a new task with the same method, entities and options
            old = obj.get(taskId);
            if ~ismember(string(old.status), ["completed", "failed", "cancelled"])
                nansen.internal.throwError("task-active", "task %s is %s", taskId, old.status)
            end
            task = struct("schemaType", old.schemaType, "schemaVersion", old.schemaVersion, ...
                "id", char(nansen.internal.uuid4()), "method", old.method, ...
                "entities", {nansen.internal.asCellOfStructs(old.entities)}, "options", old.options, ...
                "status", 'queued', "createdAt", char(nansen.internal.timestamp()), "progress", 0);
            if isfield(old, "language")
                task.language = old.language;
            end
            if isfield(old, "pipeline")
                task.pipeline = old.pipeline;
            end
            obj.save(task)
        end

        function remove(obj, taskId)
            task = obj.get(taskId);
            if string(task.status) == "running"
                nansen.internal.throwError("task-active", "task %s is running", taskId)
            end
            for path = [obj.path(taskId), obj.logPath(taskId), obj.cancelPath(taskId)]
                if isfile(path)
                    delete(path);
                end
            end
            obj.release(taskId);
            obj.emit("removed", struct("id", char(taskId)))
        end

        function removed = clear(obj)
            %clear Remove every finished task
            removed = 0;
            for task = obj.list()
                if ismember(string(task{1}.status), ["completed", "failed", "cancelled"])
                    obj.remove(string(task{1}.id));
                    removed = removed + 1;
                end
            end
        end

        function recovered = recover(obj)
            %recover Mark tasks left running by a worker that died as failed; call when no worker runs
            recovered = strings(1, 0);
            for task = obj.list("running")
                item = task{1};
                item.status = 'failed';
                item.finishedAt = char(nansen.internal.timestamp());
                item.error = struct("message", 'interrupted: the worker stopped while the task was running');
                obj.save(item)
                obj.release(string(item.id));
                recovered(end + 1) = string(item.id); %#ok<AGROW>
            end
        end

        % -- running ----------------------------------------------------------------------

        function task = nextTask(obj)
            %nextTask The oldest queued task this worker can run now: its language, not claimed, every
            %   task it waits for completed. A task waiting for one that failed or was cancelled is cancelled.
            task = [];
            tasks = obj.list();
            statuses = containers.Map("KeyType", "char", "ValueType", "char");
            for i = 1:numel(tasks)
                statuses(char(tasks{i}.id)) = char(tasks{i}.status);
            end
            for i = 1:numel(tasks)
                candidate = tasks{i};
                if string(candidate.status) ~= "queued"
                    continue
                end
                waiting = strings(1, 0);
                for other = nansen.internal.asCellstr(nansen.internal.getField(candidate, "after", {}))
                    if isKey(statuses, other{1})
                        waiting(end + 1) = string(statuses(other{1})); %#ok<AGROW>
                    else
                        waiting(end + 1) = "missing"; %#ok<AGROW>
                    end
                end
                if any(ismember(waiting, ["failed", "cancelled", "missing"]))
                    candidate.status = 'cancelled';
                    candidate.finishedAt = char(nansen.internal.timestamp());
                    candidate.error = struct("message", 'an earlier step did not complete');
                    obj.save(candidate)
                    statuses(char(candidate.id)) = 'cancelled';
                    continue
                end
                if any(waiting ~= "completed")
                    continue
                end
                if string(nansen.internal.getField(candidate, "language", "matlab")) == "matlab" ...
                        && ~isfolder(obj.claimPath(string(candidate.id)))
                    task = candidate;
                    return
                end
            end
        end

        function task = runNext(obj)
            %runNext Run the oldest queued task in this session; returns it, or [] when nothing is queued
            task = obj.claimNext();
            if isempty(task)
                return
            end
            task = nansen.runTask(obj.Project, string(task.id), OnEvent=obj.OnEvent);
        end

        function task = claimNext(obj)
            %claimNext Claim the oldest queued task this worker can take and mark it running; [] when there is none
            while true
                task = obj.nextTask();
                if isempty(task)
                    return
                end
                if obj.claim(string(task.id))
                    task = obj.get(string(task.id));
                    if string(task.status) == "queued"
                        break
                    end
                    obj.release(string(task.id));
                end
            end
            task.status = 'running';
            task.startedAt = char(nansen.internal.timestamp());
            obj.save(task)
        end

        function done = runAll(obj)
            done = {};
            while true
                task = obj.runNext();
                if isempty(task)
                    return
                end
                done{end + 1} = task; %#ok<AGROW>
            end
        end

        function start(obj, period)
            %start Run queued tasks one at a time on backgroundPool, polled by a timer
            arguments
                obj
                period (1,1) double = 0.5
            end
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                return
            end
            obj.recover();
            obj.Timer = timer(ExecutionMode="fixedSpacing", Period=period, BusyMode="drop", ...
                TimerFcn=@(~, ~) obj.poll(), Name="nansen-task-queue");
            start(obj.Timer);
        end

        function stop(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                stop(obj.Timer);
                delete(obj.Timer);
            end
            obj.Timer = [];
        end

        function tf = isRunning(obj)
            tf = ~isempty(obj.Timer) && isvalid(obj.Timer) && string(obj.Timer.Running) == "on";
        end
    end

    methods (Access = private)
        function poll(obj)
            if ~isempty(obj.Future)
                if ~ismember(string(obj.Future.State), ["finished", "failed"])
                    return
                end
                taskId = obj.FutureTaskId;
                if ~isempty(obj.Future.Error) && string(obj.get(taskId).status) == "running"
                    task = obj.get(taskId);
                    task.status = 'failed';
                    task.finishedAt = char(nansen.internal.timestamp());
                    task.error = struct("message", char("worker failed: " + obj.Future.Error.message));
                    obj.save(task)
                else
                    obj.emit("task", obj.get(taskId))
                end
                obj.Future = [];
                obj.FutureTaskId = "";
            end
            task = obj.claimNext();
            if isempty(task)
                return
            end
            obj.FutureTaskId = string(task.id);
            obj.Future = parfeval(backgroundPool, @nansen.runTask, 1, obj.Project.Folder, string(task.id));
        end
    end
end
