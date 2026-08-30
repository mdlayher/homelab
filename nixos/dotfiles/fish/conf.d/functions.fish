

function gr
  cd $(git rev-parse --show-toplevel)
end

function ...
  cd ../../
end

function ....
  cd ../../../
end

function .....
  cd ../../../../
end
