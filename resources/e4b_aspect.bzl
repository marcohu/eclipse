# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Aspect for e4b, taken from intellij_info.bzl

DEPENDENCY_ATTRIBUTES = [
  "deps",
  "runtime_deps",
  "exports",
]

def struct_omit_none(**kwargs):
    d = {name: kwargs[name] for name in kwargs if kwargs[name] != None}
    return struct(**d)

def artifact_location(file):
  return None if file == None else file.path

def library_artifact(java_output):
  if java_output == None or java_output.class_jar == None:
    return None
  return struct_omit_none(
        jar = artifact_location(java_output.class_jar),
        interface_jar = artifact_location(java_output.ijar),
        source_jar = artifact_location(java_output.source_jar),
  )

def annotation_processing_jars(annotation_processing):
  return struct_omit_none(
        jar = artifact_location(annotation_processing.class_jar),
        source_jar = artifact_location(annotation_processing.source_jar),
  )

def jars_from_output(output):
  """ Collect jars for ide-resolve-files from Java output.
  """
  if output == None:
    return []
  return [jar
          for jar in [output.class_jar, output.ijar, output.source_jar]
          if jar != None and not jar.is_source]

def java_rule_ide_info(target, ctx):
  if hasattr(ctx.rule.attr, "srcs"):
     sources = [artifact_location(file)
                for src in ctx.rule.attr.srcs
                for file in src.files]
  else:
     sources = []

  jars = [library_artifact(output) for output in target.java.outputs.jars]
  ide_resolve_files = depset([jar
       for output in target.java.outputs.jars
       for jar in jars_from_output(output)])

  gen_jars = []
  if target.java.annotation_processing and target.java.annotation_processing.enabled:
    gen_jars = [annotation_processing_jars(target.java.annotation_processing)]
    ide_resolve_files = ide_resolve_files + depset([ jar
        for jar in [target.java.annotation_processing.class_jar,
                    target.java.annotation_processing.source_jar]
        if jar != None and not jar.is_source])

  return (struct_omit_none(
                 sources = sources,
                 jars = jars,
                 generated_jars = gen_jars
          ),
          ide_resolve_files)


def _aspect_impl(target, ctx):
  kind = ctx.rule.kind
  rule_attrs = ctx.rule.attr

  ide_info_text = depset()
  ide_resolve_files = depset()
  all_deps = []

  for attr_name in DEPENDENCY_ATTRIBUTES:
    if hasattr(rule_attrs, attr_name):
      deps = getattr(rule_attrs, attr_name)
      if type(deps) == 'list':
        for dep in deps:
          if hasattr(dep, "intellij_info_files"):
           ide_info_text = ide_info_text + dep.intellij_info_files.ide_info_text
           ide_resolve_files = ide_resolve_files + dep.intellij_info_files.ide_resolve_files
        all_deps += [str(dep.label) for dep in deps]

  if hasattr(target, "java"):
    (java_rule_ide_info_struct, java_ide_resolve_files) = java_rule_ide_info(target, ctx)
    info = struct(
        label = str(target.label),
        kind = kind,
        dependencies = all_deps,
        build_file_artifact_location = ctx.build_file_path,
    ) + java_rule_ide_info_struct
    ide_resolve_files = ide_resolve_files + java_ide_resolve_files
    output = ctx.new_file(target.label.name + ".e4b-build.json")
    ctx.file_action(output, info.to_json())
    ide_info_text += depset([output])

  return struct(
      output_groups = {
        "ide-info-text" : ide_info_text,
        "ide-resolve" : ide_resolve_files,
      },
      intellij_info_files = struct(
        ide_info_text = ide_info_text,
        ide_resolve_files = ide_resolve_files,
      )
    )

e4b_aspect = aspect(implementation = _aspect_impl,
    attr_aspects = DEPENDENCY_ATTRIBUTES
)
"""Aspect for Eclipse 4 Bazel plugin.

This aspect produces information for IDE integration with Eclipse. This only
produces information for Java targets.

This aspect has two output groups:
  - ide-info-text produces .e4b-build.json files that contains information
    about target dependencies and sources files for the IDE.
  - ide-resolve build the dependencies needed for the build (i.e., artifacts
    generated by Java annotation processors).

An e4b-build.json file is a json blob with the following keys:
```javascript
{
  // Label of the corresponding target
  "label": "//package:target",
  // Kind of the corresponding target, e.g., java_test, java_binary, ...
  "kind": "java_library",
  // List of dependencies of this target
  "dependencies": ["//package1:dep1", "//package2:dep2"],
  "Path, relative to the workspace root, of the build file containing the target.
  "build_file_artifact_location": "package/BUILD",
  // List of sources file, relative to the execroot
  "sources": ["package/Test.java"],
  // List of jars created when building this target.
  "jars": [jar1, jar2],
  // List of jars generated by java annotation processors when building this target.
  "generated_jars": [genjar1, genjar2]
}
```

Jar files structure has the following keys:
```javascript
{
  // Location, relative to the execroot, of the jar file or null
  "jar": "bazel-out/host/package/libtarget.jar",
  // Location, relative to the execroot, of the interface jar file,
  // containing only the interfaces of the target jar or null.
  "interface_jar": "bazel-out/host/package/libtarget.interface-jar",
  // Location, relative to the execroot, of the source jar file,
  // containing the sources used to generate the target jar or null.
  "source_jar": "bazel-out/host/package/libtarget.interface-jar",
}
```
"""
