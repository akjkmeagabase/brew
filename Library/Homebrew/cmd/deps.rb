# frozen_string_literal: true

require "formula"
require "ostruct"
require "cli/parser"
require "cask/caskroom"

module Homebrew
  extend DependenciesHelpers

  module_function

  def deps_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `deps` [<options>] [<formula>]

        Show dependencies for <formula>. Additional options specific to <formula>
        may be appended to the command. When given multiple formula arguments,
        show the intersection of dependencies for each formula.
      EOS
      switch "-n",
             description: "Sort dependencies in topological order."
      switch "--1",
             description: "Only show dependencies one level down, instead of recursing."
      switch "--union",
             description: "Show the union of dependencies for multiple <formula>, instead of the intersection."
      switch "--full-name",
             description: "List dependencies by their full name."
      switch "--include-build",
             description: "Include `:build` dependencies for <formula>."
      switch "--include-optional",
             description: "Include `:optional` dependencies for <formula>."
      switch "--include-test",
             description: "Include `:test` dependencies for <formula> (non-recursive)."
      switch "--skip-recommended",
             description: "Skip `:recommended` dependencies for <formula>."
      switch "--include-requirements",
             description: "Include requirements in addition to dependencies for <formula>."
      switch "--tree",
             description: "Show dependencies as a tree. When given multiple formula arguments, "\
                          "show individual trees for each formula."
      switch "--annotate",
             description: "Mark any build, test, optional, or recommended dependencies as "\
                          "such in the output."
      switch "--installed",
             description: "List dependencies for formulae that are currently installed. If <formula> is "\
                          "specified, list only its dependencies that are currently installed."
      switch "--all",
             description: "List dependencies for all available formulae."
      switch "--for-each",
             description: "Switch into the mode used by the `--all` option, but only list dependencies "\
                          "for each provided <formula>, one formula per line. This is used for "\
                          "debugging the `--installed`/`--all` display mode."
      switch :verbose
      switch :debug
      conflicts "--installed", "--all"
      formula_options
    end
  end

  def deps
    deps_args.parse

    Formulary.enable_factory_cache!

    recursive = !args.send("1?")
    installed = args.installed? || dependents(args.formulae_and_casks).all?(&:any_version_installed?)

    @use_runtime_dependencies = installed && recursive &&
                                !args.tree? &&
                                !args.include_build? &&
                                !args.include_test? &&
                                !args.include_optional? &&
                                !args.skip_recommended?

    if args.tree?
      dependents = if args.named.present?
        sorted_dependents(args.formulae_and_casks)
      elsif args.installed?
        sorted_dependents(Formula.installed + Cask::Caskroom.casks)
      else
        raise FormulaUnspecifiedError
      end

      puts_deps_tree dependents, recursive
      return
    elsif args.all?
      puts_deps sorted_dependents(Formula.to_a + Cask::Cask.to_a), recursive
      return
    elsif !args.no_named? && args.for_each?
      puts_deps sorted_dependents(args.formulae_and_casks), recursive
      return
    end

    if args.no_named?
      raise FormulaUnspecifiedError unless args.installed?

      puts_deps sorted_dependents(Formula.installed + Cask::Caskroom.casks), recursive
      return
    end

    dependents = dependents(args.formulae_and_casks)

    all_deps = deps_for_dependents(dependents, recursive, &(args.union? ? :| : :&))
    condense_requirements(all_deps)
    all_deps.map!(&method(:dep_display_name))
    all_deps.uniq!
    all_deps.sort! unless args.n?
    puts all_deps
  end

  def sorted_dependents(formulae_or_casks)
    dependents(formulae_or_casks).sort_by(&:name)
  end

  def condense_requirements(deps)
    deps.select! { |dep| dep.is_a?(Dependency) } unless args.include_requirements?
    deps.select! { |dep| dep.is_a?(Requirement) || dep.installed? } if args.installed?
  end

  def dep_display_name(dep)
    str = if dep.is_a? Requirement
      if args.include_requirements?
        ":#{dep.display_s}"
      else
        # This shouldn't happen, but we'll put something here to help debugging
        "::#{dep.name}"
      end
    elsif args.full_name?
      dep.to_formula.full_name
    else
      dep.name
    end

    if args.annotate?
      str = "#{str} " if args.tree?
      str = "#{str} [build]" if dep.build?
      str = "#{str} [test]" if dep.test?
      str = "#{str} [optional]" if dep.optional?
      str = "#{str} [recommended]" if dep.recommended?
    end

    str
  end

  def deps_for_dependent(d, recursive = false)
    includes, ignores = argv_includes_ignores(ARGV)

    deps = d.runtime_dependencies if @use_runtime_dependencies

    if recursive
      deps ||= recursive_includes(Dependency, d, includes, ignores)
      reqs   = recursive_includes(Requirement, d, includes, ignores)
    else
      deps ||= reject_ignores(d.deps, ignores, includes)
      reqs   = reject_ignores(d.requirements, ignores, includes)
    end

    deps + reqs.to_a
  end

  def deps_for_dependents(dependents, recursive = false, &block)
    dependents.map { |d| deps_for_dependent(d, recursive) }.reduce(&block)
  end

  def puts_deps(dependents, recursive = false)
    dependents.each do |d|
      deps = deps_for_dependent(d, recursive)
      condense_requirements(deps)
      deps.sort_by!(&:name)
      deps.map!(&method(:dep_display_name))
      puts "#{d.full_name}: #{deps.join(" ")}"
    end
  end

  def puts_deps_tree(dependents, recursive = false)
    dependents.each do |d|
      puts d.full_name
      @dep_stack = []
      recursive_deps_tree(d, "", recursive)
      puts
    end
  end

  def recursive_deps_tree(f, prefix, recursive)
    includes, ignores = argv_includes_ignores(ARGV)
    dependables = @use_runtime_dependencies ? f.runtime_dependencies : f.deps
    deps = reject_ignores(dependables, ignores, includes)
    reqs = reject_ignores(f.requirements, ignores, includes)
    dependables = reqs + deps

    max = dependables.length - 1
    @dep_stack.push f.name
    dependables.each_with_index do |dep, i|
      next if !args.include_requirements? && dep.is_a?(Requirement)

      tree_lines = if i == max
        "└──"
      else
        "├──"
      end

      display_s = "#{tree_lines} #{dep_display_name(dep)}"
      is_circular = @dep_stack.include?(dep.name)
      display_s = "#{display_s} (CIRCULAR DEPENDENCY)" if is_circular
      puts "#{prefix}#{display_s}"

      next if !recursive || is_circular

      prefix_addition = if i == max
        "    "
      else
        "│   "
      end

      recursive_deps_tree(Formulary.factory(dep.name), prefix + prefix_addition, true) if dep.is_a? Dependency
    end

    @dep_stack.pop
  end
end
