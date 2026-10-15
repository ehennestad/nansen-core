function task = runTask(project, taskId, options)
%runTask Run one task to its end, keeping its document up to date; usable from any worker
%
%   task = nansen.runTask(project, taskId) with a nansen.Project or a
%   project folder. OnEvent(kind, data) is told about task changes and log
%   lines.
    arguments
        project
        taskId (1,1) string
        options.OnEvent = []
    end
    if ~isa(project, "nansen.Project")
        project = nansen.Project.open(project);
    end
    queue = nansen.TaskQueue(project, OnEvent=options.OnEvent);
    task = queue.get(taskId);
    task.status = 'running';
    if ~isfield(task, "startedAt")
        task.startedAt = char(nansen.internal.timestamp());
    end
    task.progress = 0;
    task.log = char("tasks/" + taskId + ".log");
    queue.save(task)
    logFile = fopen(queue.logPath(taskId), "a", "n", "UTF-8");
    closer = onCleanup(@() fclose(logFile));
    lastSaved = 0;

    context = nansen.MethodContext(Project=project, OnLog=@onLog, OnProgress=@onProgress);
    try
        method = project.method(string(task.method.id));
        context.Method = method;
        if isfile(queue.cancelPath(taskId))
            context.cancel();
        end
        references = nansen.internal.asCellOfStructs(task.entities);
        entities = cellfun(@(r) project.entity(string(r.entityType), r.key), references, UniformOutput=false);
        context.log("%s %s on %d %s(s)", method.Id, method.Version, numel(entities), entities{1}.EntityType);
        results = nansen.runMethod(method, entities, task.options.values, context);
        nansen.internal.recordRuns(project.Folder, method.Id, method.Version, entities, string(taskId));
        task.status = 'completed';
        task.progress = 1;
        if method.BatchMode == "batch"
            results = results{1};
        end
        try
            text = jsonencode(results);
            if strlength(text) <= 64 * 1024
                task.result = jsondecode(text);
            end
        catch
            % not JSON; the task still completed
        end
        context.log("completed");
    catch err
        if err.identifier == "nansen:Cancelled"
            task.status = 'cancelled';
            onLog("cancelled");
        else
            stack = arrayfun(@(s) sprintf("%s:%d", s.name, s.line), err.stack, UniformOutput=false);
            task.status = 'failed';
            task.error = struct("identifier", err.identifier, "message", err.message, "stack", {stack(1:min(end, 20))'});
            onLog("failed: " + err.message);
        end
    end
    if isfile(queue.cancelPath(taskId))
        delete(queue.cancelPath(taskId));
    end
    task.finishedAt = char(nansen.internal.timestamp());
    queue.save(task)
    queue.release(taskId);

    function onLog(line)
        fprintf(logFile, "%s\n", line);
        queue.emit("log", struct("id", char(taskId), "line", char(line)))
    end

    function onProgress(fraction, message)
        if isfile(queue.cancelPath(taskId))
            context.cancel();
        end
        task.progress = round(fraction, 4);
        if strlength(message) > 0
            task.message = char(message);
        end
        stamp = posixtime(datetime("now"));
        if stamp - lastSaved > 0.25 || fraction >= 1
            lastSaved = stamp;
            queue.save(task)
        end
    end
end
