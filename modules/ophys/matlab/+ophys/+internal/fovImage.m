function image = fovImage(data)
%fovImage An image, height x width; a stack is averaged over frames
    image = double(data);
    if ndims(image) == 3
        image = mean(image, 3);
    end
    if ~ismatrix(image)
        nansen.internal.throwError("invalid-data", "an image is height x width (or a stack to average), not %s", mat2str(size(image)))
    end
end
