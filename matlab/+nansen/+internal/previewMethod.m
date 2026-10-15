function result = previewMethod(project, methodId, entity, options, preset, frames, column, maxPoints)
%previewMethod Run a method on one entity with its stacks cut to their first frames, saving nothing (methods.preview)
%
%   Returns frames, results (what the method returned), outputs (per
%   variable it saved: see nansen.internal.describeOutput) and log, as
%   Python's nansen.preview.preview. With a column (0-based; [] for none),
%   the method runs on that column of each frames x N array it loads (see
%   nansen.internal.PreviewProject), and each output of one column gives
%   its values thinned to maxPoints (default 2000), as data.traces.
    if nargin < 7
        column = [];
    end
    if nargin < 8
        maxPoints = 2000;
    end
    if frames < 1
        nansen.internal.throwError("invalid-params", "frames is 1 or more")
    end
    if ~isempty(column) && ~(isnumeric(column) && isscalar(column) && column >= 0 && column == round(column))
        nansen.internal.throwError("invalid-params", "column is a 0-based column number")
    end
    method = project.method(methodId);
    values = struct();
    if strlength(preset) > 0
        values = project.preset(methodId, preset);
    end
    values = nansen.internal.mergeStructs(values, options);
    sandbox = nansen.internal.PreviewProject(project, frames, column);
    cleanup = onCleanup(@() sandbox.close());
    context = nansen.MethodContext(Project=sandbox, Method=method);
    results = nansen.runMethod(method, {entity}, values, context);
    outputs = cell(1, numel(sandbox.Names));
    for i = 1:numel(sandbox.Names)
        if isempty(column)
            outputs{i} = nansen.internal.describeOutput(sandbox.Names(i), sandbox.Values{i});
        else
            outputs{i} = nansen.internal.describeOutput(sandbox.Names(i), sandbox.Values{i}, maxPoints);
        end
    end
    result = struct("frames", frames, "results", {results}, "outputs", {outputs}, "log", {cellstr(context.Lines)});
end
