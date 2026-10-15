function stack = loadStack(context, entity, name)
%loadStack The variable's stack, height x width x frames (one frame for an image)
    stack = context.Project.load(entity, name);
    if ndims(stack) > 3
        nansen.internal.throwError("invalid-data", ...
            "%s is %s; ophys methods take one channel, height x width x frames", name, mat2str(size(stack)))
    end
end
