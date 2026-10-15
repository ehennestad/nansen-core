function done = worker(folder, options)
%worker Run a project's queued MATLAB tasks in this session, without the app
%
%   done = nansen.worker(folder) runs them one after another until
%   interrupted (Ctrl+C); with UntilEmpty=true it returns when none is left
%   for MATLAB. Tasks for Python are left to a Python worker. A worker for
%   tasks a Python app queued for MATLAB, e.g.
%       matlab -batch "nansen.worker('~/nansen/Pilot', UntilEmpty=true)"
%   Python's equivalent is the command nansen worker <folder>.
    arguments
        folder (1,1) string
        options.UntilEmpty (1,1) logical = false
        options.Environment (1,1) string = ""
        options.Poll (1,1) double = 1
    end
    project = nansen.Project.open(folder, Environment=options.Environment);
    queue = nansen.TaskQueue(project);   % no recover: an app's worker may be running a task as this one starts
    done = {};
    while true
        task = queue.runNext();
        if ~isempty(task)
            done{end + 1} = task; %#ok<AGROW>
            fprintf("%-9s %s %s\n", task.status, task.method.id, task.id);
        elseif options.UntilEmpty
            return
        else
            pause(options.Poll);
        end
    end
end
