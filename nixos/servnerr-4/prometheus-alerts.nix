{
  groups = [{
    name = "default";
    rules = [
      # PCs which don't run 24/7 are excluded from alerts, and lab-* jobs are
      # excluded due to their experimental nature.
    ];
  }];
}
