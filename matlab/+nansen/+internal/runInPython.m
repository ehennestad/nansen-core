function result = runInPython(project, methodId, entities, values, options)
%runInPython Run a method's Python implementation now, as a task for Python, and return what it returned
%
%   result = nansen.internal.runInPython(project, methodId, entities, values)
%   queues the method on the entities (a cell array) for Python, as
%   methods.run hands Python a method MATLAB does not have
%   (nansen.TaskQueue.submit with Language "python"), claims the task so
%   that no Python worker takes it as well, and runs it with the command a
%   Python worker runs one task with, waiting for it:
%       <python> -m nansen run-task <project folder> <task id> [--environment <environment>]
%   The Python is nansen.internal.pythonExecutable (NANSEN_PYTHON, MATLAB's
%   pyenv, or python3). The task stays on the queue, with its result and
%   log. A Python that does not run the task (it is missing, or has no
%   nansen-core) is dependency-missing, the task marked failed; the
%   method's own error in Python comes with its code (task-failed when it
%   has none), and a task cancelled there is nansen:Cancelled. Hint is
%   added to a dependency-missing message.
    arguments
        project
        methodId (1,1) string
        entities (1,:) cell
        values = struct()
        options.Hint (1,1) string = ""
    end
    queue = nansen.TaskQueue(project);
    task = queue.submit(methodId, entities, Options=values, Language="python");
    taskId = string(task.id);
    queue.claim(taskId);   % a Python worker takes only tasks no one has claimed
    releaser = onCleanup(@() queue.release(taskId)); %#ok<NASGU>
    executable = nansen.internal.pythonExecutable();
    command = string(sprintf('"%s" -m nansen run-task "%s" %s', executable, project.Folder, taskId));
    if project.Environment ~= ""
        command = command + string(sprintf(' --environment "%s"', project.Environment));
    end
    hint = "";
    if options.Hint ~= ""
        hint = "; " + options.Hint;
    end
    [~, output] = system(command + " 2>&1");
    task = queue.get(taskId);
    status = string(task.status);
    if any(status == ["queued", "running"])   % Python did not run it to its end
        said = strtrim(string(output));
        if strlength(said) > 400
            said = "..." + extractAfter(said, strlength(said) - 400);
        end
        task.status = 'failed';
        task.finishedAt = char(nansen.internal.timestamp());
        task.error = struct("message", char("could not run " + executable + " -m nansen: " + said));
        queue.save(task)
        nansen.internal.throwError("dependency-missing", ...
            "%s runs in Python here, and %s -m nansen run-task did not run it (%s): set NANSEN_PYTHON, or MATLAB's pyenv, to a Python with nansen-core%s", ...
            methodId, executable, said, hint)
    end
    if status == "cancelled"
        error("nansen:Cancelled", "The run was cancelled")
    end
    if status ~= "completed"
        message = "";
        if isfield(task, "error") && isstruct(task.error) && isfield(task.error, "message")
            message = string(task.error.message);
        end
        tokens = regexp(char(message), '^\[([a-z][a-z-]*)\] (.*)$', 'tokens', 'once');
        if ~isempty(tokens)   % a NansenError in Python: "[code] message"
            if string(tokens{1}) == "dependency-missing"
                nansen.internal.throwError("dependency-missing", "%s (in Python)%s", tokens{2}, hint)
            end
            nansen.internal.throwError(tokens{1}, "%s (in Python)", tokens{2})
        end
        nansen.internal.throwError("task-failed", "%s %s in Python: %s", methodId, status, message)
    end
    result = [];
    if isfield(task, "result")
        result = task.result;
    end
end
