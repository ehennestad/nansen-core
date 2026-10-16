function result = runFileMethod(method, file, options, context)
%runFileMethod Run a file method in this MATLAB session: once, as function(file, options, context)
%
%   result = nansen.runFileMethod(method, file, options, context) with file
%   a struct {path, root}: the file, and the folder of the data location
%   it is in (or the project folder), as dev's project filemethods
%   (filemethod.downloadFile(filePath, rootPath)) got them; options a
%   struct of values over the defaults. Returns what the method returned
%   ([] for nothing).
    arguments
        method (1,1) nansen.Method
        file (1,1) struct
        options = struct()
        context = nansen.MethodContext(Method=method)
    end
    if ~method.isFileMethod()
        nansen.internal.throwError("wrong-entity-type", "%s runs on %s, not on a file", method.Id, method.EntityType)
    end
    resolved = method.resolveOptions(options);
    handle = method.functionHandle();
    context.checkCancelled()
    if nargout(handle) == 0
        handle(file, resolved, context);
        result = [];
    else
        result = handle(file, resolved, context);
    end
    context.progress(1)
end
