function result = nansenCoreWait(entity, options, context)
%nansenCoreWait Wait in steps, reporting progress and stopping when cancelled
    for step = 1:options.steps
        context.checkCancelled()
        pause(options.seconds / options.steps);
        context.progress(step / options.steps, sprintf("%s %d/%d", options.message, step, options.steps));
    end
    context.log("%s: done %s", strjoin(string(struct2cell(entity.Key)), " / "), options.message);
    if options.fail
        error("nansen:core:Failed", "failed on purpose")
    end
    result = struct("waited", options.seconds);
end
