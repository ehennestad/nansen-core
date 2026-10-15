function stack = openStack(context, entity, name)
%openStack The variable as a height x width x frames nansen.Stack read a chunk at a time (an image is one frame)
    stack = context.Project.openStack(entity, name);
    if ndims(stack) == 2
        limit = stack.MaxFrames;
        stack.MaxFrames = Inf;   % an image's columns are not frames
        stack = nansen.Stack.fromArray(stack.all(), 3);   % an image: one frame
        stack.MaxFrames = limit;
    end
    if ndims(stack) > 3
        nansen.internal.throwError("invalid-data", ...
            "%s is %s; ophys methods take one channel, height x width x frames", name, mat2str(size(stack)))
    end
end
