function stack = loadStack(context, entity, name)
%loadStack The variable's stack, height x width x frames (one frame for an image), read whole: for methods
%that need every frame at once (the others read a chunk at a time with openStack)
    stack = all(ophys.internal.openStack(context, entity, name));
end
