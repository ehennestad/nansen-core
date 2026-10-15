function result = runTool(method, project, options, context)
%runTool Run a project tool in this MATLAB session: once, as function(project, options, context)
%
%   result = nansen.runTool(method, project, options, context) with options a
%   struct of values over the defaults. Returns what the tool returned ([] for nothing).
    arguments
        method (1,1) nansen.Method
        project
        options = struct()
        context = nansen.MethodContext(Method=method)
    end
    if ~method.isTool()
        nansen.internal.throwError("wrong-entity-type", "%s runs on %s, not on the project", method.Id, method.EntityType)
    end
    resolved = method.resolveOptions(options);
    handle = method.functionHandle();
    context.checkCancelled()
    if nargout(handle) == 0
        handle(project, resolved, context);
        result = [];
    else
        result = handle(project, resolved, context);
    end
    context.progress(1)
end
