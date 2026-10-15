function result = previewMethod(project, methodId, entity, options, preset, frames)
%previewMethod Run a method on one entity with its stacks cut to their first frames, saving nothing (methods.preview)
%
%   Returns frames, results (what the method returned), outputs (per
%   variable it saved: see nansen.internal.describeOutput) and log, as
%   Python's nansen.preview.preview.
    if frames < 1
        nansen.internal.throwError("invalid-params", "frames is 1 or more")
    end
    method = project.method(methodId);
    values = struct();
    if strlength(preset) > 0
        values = project.preset(methodId, preset);
    end
    values = nansen.internal.mergeStructs(values, options);
    sandbox = nansen.internal.PreviewProject(project, frames);
    cleanup = onCleanup(@() sandbox.close());
    context = nansen.MethodContext(Project=sandbox, Method=method);
    results = nansen.runMethod(method, {entity}, values, context);
    outputs = cell(1, numel(sandbox.Names));
    for i = 1:numel(sandbox.Names)
        outputs{i} = nansen.internal.describeOutput(sandbox.Names(i), sandbox.Values{i});
    end
    result = struct("frames", frames, "results", {results}, "outputs", {outputs}, "log", {cellstr(context.Lines)});
end
