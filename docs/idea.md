# Idea

A workflow execution engine implemented in Haskell. The workflow will be defined entirely in markdown and json files.

## Problem

When building a workflow or agentic system, system prompts and descriptions are often embeddend in source code files, as string constants. Changing the workflow requires recompilation. The workflow language I want to build consists only of markdown and a few json files.

## Goal

The goal is to be able to define a complex workflow in markdown files, including tools that can run sub-workflows.

The program will be invoked on the command line. It will first type-check all the files and the workflow structure before it starts to run them.

It will have access to a workspace folder where it can read, create and modify files.

The state and traces of the execution should be persisted and it should be resumable in case of a crash or abort.

In a later stage, agents should also be able to generate workflows and run them dynamically. They should also be able to read thier own traces and maybe learn from them or create skills.

## Non-goals

There will be no GUI

## Constraints

- for calling LLMs, we will use the llm-simple library located at '../llm-simple'
- GHC2021 language

## Open questions
