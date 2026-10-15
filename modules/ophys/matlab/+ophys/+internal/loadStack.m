function stack = loadStack(context, entity, name, options)
%loadStack The variable's stack, height x width x frames (one frame for an image), read whole: for methods
%that need every frame at once (the others read a chunk at a time with openStack). The options' channel and
%plane are picked from a stack that has them.
    if nargin < 4
        options = struct();
    end
    stack = all(ophys.internal.openStack(context, entity, name, options));
end
