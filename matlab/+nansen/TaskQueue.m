classdef TaskQueue < handle
%TaskQueue The tasks of one project: methods queued on entities, kept as nansen.task documents
%
%   queue = nansen.TaskQueue(project) works on <project>/tasks. A task file
%   describes everything a worker needs, so it can run in this session, on
%   a background worker, or in Python. While a task runs its worker owns the
%   file; anyone else asks it to stop by creating tasks/<id>.cancel.
%
%   OnEvent(kind, data) is called with kind "task" (a task changed) or "log".
%   runNext/runAll run tasks in this session; start() runs them on a
%   worker, polled by a timer, until stop(): Worker "thread" is
%   backgroundPool, "process" a process pool of the Parallel Computing
%   Toolbox (the current one, or a new one), for methods that cannot run on
%   a thread, as dev ran tasks.

    properties
        OnEvent = []
        Worker (1,1) string {mustBeMember(Worker, ["thread", "process"])} = "thread"   % from the next task on
    end

    properties (SetAccess = private)
        Project
        Folder (1,1) string
    end

    properties (Access = private)
        Timer = []
        Future = []
        FutureTaskId (1,1) string = ""
        LastCreated = datetime.empty   % creation times this queue gives out only grow, so tasks keep the order they were queued in
    end

    methods
        function obj = TaskQueue(project, options)
            arguments
                project
                options.OnEvent = []
                options.Worker (1,1) string = "thread"
            end
            obj.Project = project;
            obj.Folder = string(fullfile(project.Folder, "tasks"));
            obj.OnEvent = options.OnEvent;
            obj.Worker = options.Worker;
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
            task = nansen.TaskQueue.readTask(obj.path(taskId));
            if isempty(task)
                nansen.internal.throwError("unknown-task", "no task '%s'", taskId)
            end
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
                task = nansen.TaskQueue.readTask(fullfile(obj.Folder, listing(i).name));
                if ~isempty(task)
                    tasks{end + 1} = task; %#ok<AGROW>
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
            [~, suffix] = fileparts(tempname);   % a worker thread shares this process's id
            temporary = path + "." + string(suffix) + ".tmp";
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
                % runKeyId of an entity -> the numbers (from 0) of the steps to leave out, as when only
                % the steps not done yet are queued
                options.Skip = containers.Map("KeyType", "char", "ValueType", "any")
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
                leftOut = [];
                id = nansen.internal.runKeyId(entities{i}.Key);
                if isKey(options.Skip, id)
                    leftOut = options.Skip(id);
                end
                for s = 1:numel(steps)
                    if ismember(s - 1, leftOut)
                        continue
                    end
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
                "createdAt", char(obj.createdAt()), "progress", 0);
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
                "status", 'queued', "createdAt", char(obj.createdAt()), "progress", 0);
            if isfield(old, "language")
                task.language = old.language;
            end
            if isfield(old, "pipeline")
                task.pipeline = old.pipeline;
            end
            obj.save(task)
        end

        function task = hold(obj, taskId, onHold)
            %hold Keep a queued task from starting (true) or let it start again (false); it keeps its place
            arguments
                obj
                taskId (1,1) string
                onHold (1,1) logical = true
            end
            task = obj.requireChanged(taskId, obj.changeQueued(taskId, @(t) withHold(t, onHold)));
        end

        function task = update(obj, taskId, options)
            %update Give a queued task new options: the preset's values (if given) with these on top, resolved and validated
            arguments
                obj
                taskId (1,1) string
                options.Options = struct()
                options.Preset (1,1) string = ""
            end
            method = obj.Project.method(string(obj.get(taskId).method.id));
            base = struct();
            if options.Preset ~= ""
                base = obj.Project.preset(method.Id, options.Preset);
            end
            values = options.Options;
            if isempty(values)
                values = struct();
            end
            resolved = method.resolveOptions(nansen.internal.mergeStructs(base, values));
            entry = struct("values", resolved);
            if options.Preset ~= ""
                entry.preset = char(options.Preset);
            end
            version = char(method.Version);
            task = obj.requireChanged(taskId, obj.changeQueued(taskId, @(t) withOptions(t, entry, version)));
        end

        function result = reorder(obj, taskIds)
            %reorder Put these queued tasks first, in this order; the other queued tasks follow in the order they had
            %
            %   Returns the queued tasks in their new order (a cell row). A task
            %   cannot run before the tasks it waits for, whatever its place.
            taskIds = reshape(string(taskIds), 1, []);
            queued = nansen.TaskQueue.inQueueOrder(obj.list("queued"));
            known = string(cellfun(@(t) char(t.id), queued, UniformOutput=false));
            for taskId = taskIds
                if ~ismember(taskId, known)
                    obj.get(taskId);   % unknown-task
                    nansen.internal.throwError("task-not-queued", "task %s is not queued", taskId)
                end
            end
            if numel(unique(taskIds)) ~= numel(taskIds)
                nansen.internal.throwError("invalid-params", "a task is listed twice")
            end
            [~, at] = ismember(taskIds, known);
            rest = setdiff(1:numel(queued), at, "stable");
            ordered = queued([at, rest]);
            result = {};
            for i = 1:numel(ordered)
                task = ordered{i};
                position = i - 1;
                if ~isequal(nansen.internal.getField(task, "order", []), position)
                    try
                        changed = obj.changeQueued(string(task.id), @(t) setfield(t, "order", position)); %#ok<SFLD>
                    catch err
                        if isa(err, "nansen.NansenError")
                            continue   % it left the queue meanwhile
                        end
                        rethrow(err)
                    end
                    if ~isempty(changed)
                        task = changed;
                    end
                end
                result{end + 1} = task; %#ok<AGROW>
            end
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
            if isempty(tasks)
                return
            end
            queued = nansen.TaskQueue.inQueueOrder(tasks(cellfun(@(t) string(t.status) == "queued", tasks)));
            for i = 1:numel(queued)
                candidate = queued{i};
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
                if any(waiting ~= "completed") || isequal(nansen.internal.getField(candidate, "onHold", false), true)
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
                    if string(task.status) == "queued" && ~isequal(nansen.internal.getField(task, "onHold", false), true)
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
            %start Run queued tasks one at a time on the worker, polled by a timer
            arguments
                obj
                period (1,1) double = 0.5
            end
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                return
            end
            if obj.Worker == "process" && ~nansen.TaskQueue.hasProcessPools()
                nansen.internal.throwError("dependency-missing", ...
                    "running tasks in processes needs the Parallel Computing Toolbox; set the worker to thread")
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
            try
                pool = obj.pool();
            catch err   % no process pool could start: the task fails, saying why
                task.status = 'failed';
                task.finishedAt = char(nansen.internal.timestamp());
                task.error = struct("message", char("could not start the worker: " + err.message));
                obj.save(task)
                obj.release(string(task.id));
                return
            end
            obj.FutureTaskId = string(task.id);
            obj.Future = parfeval(pool, @nansen.runTask, 1, obj.Project.Folder, string(task.id));
        end

        function pool = pool(obj)
            % backgroundPool, or for Worker "process" the current process pool, else a new one
            if obj.Worker == "thread"
                pool = backgroundPool;
                return
            end
            pool = gcp("nocreate");
            if isempty(pool) || ~isa(pool, "parallel.ProcessPool")
                pool = parpool("Processes");
            end
        end
    end

    methods (Static)
        function task = readTask(path)
            %readTask A task document, or [] when there is none; read again for a moment when the file is
            %missing or unreadable, as it is while a worker replaces it (movefile is not an atomic replace)
            task = [];
            for attempt = 1:10
                if isfile(path)
                    try
                        task = nansen.readDocument(path, ExpectedType="nansen.task");
                        return
                    catch err
                        if ~isa(err, "nansen.NansenError")
                            rethrow(err)
                        end
                    end
                end
                pause(0.02);
            end
        end

        function tf = hasProcessPools()
            %hasProcessPools Whether this MATLAB has the Parallel Computing Toolbox, licensed
            tf = ~isempty(ver("parallel")) && license("test", "Distrib_Computing_Toolbox");
        end
    end

    methods (Access = private)
        function text = createdAt(obj)
            %createdAt Now, or a millisecond after the last task this queue made when that is not earlier
            %
            %   Tasks queued within one millisecond would otherwise be ordered by their random ids.
            created = datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss.SSS");
            created = dateshift(created, "start", "second") + milliseconds(floor(1000 * (second(created) - floor(second(created)))));
            if ~isempty(obj.LastCreated) && created <= obj.LastCreated
                created = obj.LastCreated + milliseconds(1);
            end
            obj.LastCreated = created;
            text = string(created);
        end

        function task = changeQueued(obj, taskId, change)
            %changeQueued Change a queued task while holding its claim, so no worker starts it meanwhile
            %
            %   Returns the changed task, or [] when a worker is taking it right now.
            obj.get(taskId);   % unknown-task
            task = [];
            if ~obj.claim(taskId)
                return
            end
            cleanup = onCleanup(@() obj.release(taskId));
            current = obj.get(taskId);
            if string(current.status) ~= "queued"
                nansen.internal.throwError("task-not-queued", "task %s is %s", taskId, current.status)
            end
            task = change(current);
            obj.save(task)
        end

        function task = requireChanged(~, taskId, task)
            if isempty(task)
                nansen.internal.throwError("task-not-queued", "task %s is being started", taskId)
            end
        end
    end

    methods (Static)
        function tasks = inQueueOrder(tasks)
            %inQueueOrder Queued tasks in the order they start: those with an order, lowest first, then by creation
            if isempty(tasks)
                return
            end
            keys = strings(1, numel(tasks));
            for i = 1:numel(tasks)
                order = nansen.internal.getField(tasks{i}, "order", []);
                if isempty(order)
                    prefix = "1" + sprintf("%012d", 0);
                else
                    prefix = "0" + sprintf("%012d", order);
                end
                keys(i) = prefix + " " + string(tasks{i}.createdAt) + " " + string(tasks{i}.id);
            end
            [~, sorting] = sort(keys);
            tasks = tasks(sorting);
        end
    end
end

function task = withHold(task, onHold)
    if onHold
        task.onHold = true;
    elseif isfield(task, "onHold")
        task = rmfield(task, "onHold");
    end
end

function task = withOptions(task, entry, version)
    task.options = entry;
    task.method.version = version;
end
