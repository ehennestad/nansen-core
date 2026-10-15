function results = runMethod(method, entities, options, context, settings)
%runMethod Run a method in this MATLAB session: once per entity (serial) or once for all (batch)
%
%   results = nansen.runMethod(method, entities, options, context) with
%   entities a cell array of nansen.Entity and options a struct of values
%   over the defaults. Returns a cell array of what the method returned
%   (one cell for a batch method). A method imported from NANSEN dev
%   (legacySessionMethod) is run by nansen.legacy.runSessionMethod, which
%   calls dev's code with a nansen.legacy.SessionShim per entity.
%   OnDone(entities) is told the entities
%   the method has completed on as it goes: each one as soon as it is done
%   (serial), or all of them at the end (batch), so a run that stops part
%   way still records those it finished.
    arguments
        method (1,1) nansen.Method
        entities (1,:) cell
        options = struct()
        context = nansen.MethodContext(Method=method)
        settings.OnDone = []
    end
    results = {};
    if isempty(entities)
        return
    end
    for i = 1:numel(entities)
        if ~method.appliesTo(entities{i}.EntityType)
            nansen.internal.throwError("wrong-entity-type", "%s runs on %s, not %s", ...
                method.Id, method.EntityType, entities{i}.EntityType)
        end
    end
    resolved = method.resolveOptions(options);
    handle = method.functionHandle();
    if method.isLegacy()   % dev's function or class, called with dev's session objects
        if isempty(context.Method)
            context.Method = method;
        end
        handle = @nansen.legacy.runSessionMethod;
    end
    if method.BatchMode == "batch"
        context.checkCancelled()
        results = {callMethod(handle, entities, resolved, context)};
        if ~isempty(settings.OnDone)
            settings.OnDone(entities);
        end
        context.progress(1)
        return
    end
    results = cell(1, numel(entities));
    for i = 1:numel(entities)
        context.checkCancelled()
        results{i} = callMethod(handle, entities{i}, resolved, context);
        if ~isempty(settings.OnDone)
            settings.OnDone(entities(i));
        end
        context.progress(i / numel(entities))
    end
end

function result = callMethod(handle, input, options, context)
    % A method may return nothing.
    if nargout(handle) == 0
        handle(input, options, context);
        result = [];
    else
        result = handle(input, options, context);
    end
end
