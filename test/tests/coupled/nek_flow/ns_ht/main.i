Ra = 1.7e5
Pr = 0.7
kappa = '${fparse 1.0 / sqrt(Ra * Pr)}'

[Mesh]
  type = GeneratedMesh
  dim = 3
  xmin = -0.5
  xmax = 0.5
  ymin = -0.5
  ymax = 0.5
  zmin = -2
  zmax = 2
  nx = 3
  ny = 2
  nz = 2
[]

[Variables]
  [temperature]
  []
[]

[AuxVariables]
  [velocity_x]
  []
  [velocity_y]
  []
  [velocity_z]
  []
[]

[ICs]
  [temperature]
    type = FunctionIC
    variable = temperature
    function = initial_temperature
  []
[]

[Functions]
  [initial_temperature]
    type = ParsedFunction
    expression = '(2-z)/4+0.01*cos(pi*x)*cos(pi*y)*sin(pi*(z+2)/4)'
  []
[]

[Kernels]
  [time]
    type = TimeDerivative
    variable = temperature
  []
  [advection]
    type = ConservativeAdvection
    variable = temperature
    velocity_material = velocity
  []
  [diffusion]
    type = CoefDiffusion
    variable = temperature
    coef = ${kappa}
  []
[]

[Materials]
  [velocity]
    type = VectorFromComponentVariablesMaterial
    vector_prop_name = velocity
    u = velocity_x
    v = velocity_y
    w = velocity_z
  []
[]

[BCs]
  [bottom]
    type = DirichletBC
    variable = temperature
    boundary = back
    value = 1
  []
  [top]
    type = DirichletBC
    variable = temperature
    boundary = front
    value = 0
  []
[]

[Executioner]
  type = Transient
  dt = 5e-3
  end_time = 0.01
  solve_type = NEWTON
  nl_abs_tol = 1e-10
[]

[MultiApps]
  [nek]
    type = TransientMultiApp
    app_type = CardinalApp
    input_files = nek.i
    execute_on = timestep_begin
  []
[]

[Transfers]
  # At timestep_begin, transfers to the sub-app run before NekRS and transfers
  # from the sub-app run afterward. This gives one loose coupling sweep per step.
  [temperature_to_nek]
    type = MultiAppGeneralFieldNearestLocationTransfer
    source_variable = temperature
    to_multi_app = nek
    variable = temperature
    greedy_search = true
  []
  [velocity_x_from_nek]
    type = MultiAppGeneralFieldNearestLocationTransfer
    source_variable = velocity_x
    from_multi_app = nek
    variable = velocity_x
    greedy_search = true
  []
  [velocity_y_from_nek]
    type = MultiAppGeneralFieldNearestLocationTransfer
    source_variable = velocity_y
    from_multi_app = nek
    variable = velocity_y
    greedy_search = true
  []
  [velocity_z_from_nek]
    type = MultiAppGeneralFieldNearestLocationTransfer
    source_variable = velocity_z
    from_multi_app = nek
    variable = velocity_z
    greedy_search = true
  []
[]

[Postprocessors]
  [average_temperature]
    type = ElementAverageValue
    variable = temperature
  []
  [maximum_vertical_velocity]
    type = ElementExtremeValue
    variable = velocity_z
    value_type = max
  []
[]

[Outputs]
  exodus = true
  csv = true
[]
