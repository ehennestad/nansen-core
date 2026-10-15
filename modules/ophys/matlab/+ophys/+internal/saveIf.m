function saveIf(context, entity, name, data)
%saveIf Save the data in the variable, unless the name is empty
    if strlength(string(name)) > 0
        context.Project.save(entity, name, data);
    end
end
