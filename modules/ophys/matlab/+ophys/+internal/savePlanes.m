function savePlanes(context, entity, name, images, every)
%savePlanes Images (height x width, a cell array) of one plane, or with every plane of each, saved in the variable
%
%   Of every plane they are saved as height x width x 1 x planes x 1: a
%   stack of one channel and one frame, its planes on their own axis, as
%   data.frame's plane picks them. MATLAB drops a last dimension of 1, so
%   the array is written again by a stack writer, which keeps it (the save
%   makes the variable when the project has none). Nothing is saved when
%   the name is empty. As Python's _save_planes.
    if strlength(string(name)) == 0
        return
    end
    if ~every
        context.Project.save(entity, name, images{1});
        return
    end
    data = cat(4, images{:});   % height x width x 1 x planes
    context.Project.save(entity, name, data);
    writer = context.Project.stackWriter(entity, name, [size(images{1}, 1), size(images{1}, 2), 1, numel(images), 1], class(data));
    writer.write(1, data);
    writer.close();
end
