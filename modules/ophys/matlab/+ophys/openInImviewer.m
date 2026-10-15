function result = openInImviewer(entity, options, context)
%openInImviewer Open the stack in NANSEN's imviewer, when it is on the path
    if isempty(which("imviewer"))   % exist misses it: NANSEN dev also has an imviewer package
        nansen.internal.throwError("dependency-missing", ...
            "ophys.open_in_imviewer needs imviewer from NANSEN on the MATLAB path")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack);
    feval("imviewer", stack);
    context.log("%s: opened %s in imviewer", ophys.internal.entityName(entity), options.stack);
    result = struct("opened", true);
end
