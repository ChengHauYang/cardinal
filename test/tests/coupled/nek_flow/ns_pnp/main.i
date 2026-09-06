lambda = 0.5
zeta = -0.2
permittivity = '${fparse 2 * lambda^2}'
charge_force = 1

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
  nz = 4
[]

[Variables]
  [c_positive]
  []
  [c_negative]
  []
  [potential]
  []
[]

[AuxVariables]
  [velocity_x]
  []
  [velocity_y]
  []
  [velocity_z]
  []
  [electric_force_x]
  []
[]

[Functions]
  [potential_initial]
    type = ParsedFunction
    expression = 'zeta*cosh(z/lambda)/cosh(2/lambda)'
    symbol_names = 'zeta lambda'
    symbol_values = '${zeta} ${lambda}'
  []
  [positive_initial]
    type = ParsedFunction
    expression = '1-zeta*cosh(z/lambda)/cosh(2/lambda)'
    symbol_names = 'zeta lambda'
    symbol_values = '${zeta} ${lambda}'
  []
  [negative_initial]
    type = ParsedFunction
    expression = '1+zeta*cosh(z/lambda)/cosh(2/lambda)'
    symbol_names = 'zeta lambda'
    symbol_values = '${zeta} ${lambda}'
  []
[]

[ICs]
  [potential]
    type = FunctionIC
    variable = potential
    function = potential_initial
  []
  [positive]
    type = FunctionIC
    variable = c_positive
    function = positive_initial
  []
  [negative]
    type = FunctionIC
    variable = c_negative
    function = negative_initial
  []
[]

[Kernels]
  [positive_time]
    type = ADTimeDerivative
    variable = c_positive
  []
  [positive_diffusion]
    type = ADDiffusion
    variable = c_positive
  []
  [positive_migration]
    type = ADConservativeAdvection
    variable = c_positive
    velocity_as_variable_gradient = potential
    velocity_scalar_coef = -1
  []
  [positive_fluid_advection]
    type = ADConservativeAdvection
    variable = c_positive
    velocity_material = velocity
  []

  [negative_time]
    type = ADTimeDerivative
    variable = c_negative
  []
  [negative_diffusion]
    type = ADDiffusion
    variable = c_negative
  []
  [negative_migration]
    type = ADConservativeAdvection
    variable = c_negative
    velocity_as_variable_gradient = potential
    velocity_scalar_coef = 1
  []
  [negative_fluid_advection]
    type = ADConservativeAdvection
    variable = c_negative
    velocity_material = velocity
  []

  [potential_diffusion]
    type = ADMatDiffusion
    variable = potential
    diffusivity = ${permittivity}
  []
  [positive_charge]
    type = ADCoupledForce
    variable = potential
    v = c_positive
    coef = 1
  []
  [negative_charge]
    type = ADCoupledForce
    variable = potential
    v = c_negative
    coef = -1
  []
[]

[AuxKernels]
  [electric_force_x]
    type = ParsedAux
    variable = electric_force_x
    coupled_variables = 'c_positive c_negative'
    expression = '${fparse charge_force / 2}*(c_positive-c_negative)'
    execute_on = 'INITIAL TIMESTEP_END'
  []
[]

[Materials]
  [velocity]
    type = ADVectorFromComponentVariablesMaterial
    vector_prop_name = velocity
    u = velocity_x
    v = velocity_y
    w = velocity_z
  []
[]

[BCs]
  [potential_walls]
    type = ADDirichletBC
    variable = potential
    boundary = 'back front'
    value = ${zeta}
  []
  [positive_walls]
    type = ADDirichletBC
    variable = c_positive
    boundary = 'back front'
    value = '${fparse 1 - zeta}'
  []
  [negative_walls]
    type = ADDirichletBC
    variable = c_negative
    boundary = 'back front'
    value = '${fparse 1 + zeta}'
  []
[]

[Executioner]
  type = Transient
  dt = 5e-3
  end_time = 0.01
  solve_type = NEWTON
  automatic_scaling = true
  nl_rel_tol = 1e-8
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
  [electric_force_to_nek]
    type = MultiAppGeneralFieldNearestLocationTransfer
    source_variable = electric_force_x
    to_multi_app = nek
    variable = electric_force_x
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
  [positive_inventory]
    type = ElementIntegralVariablePostprocessor
    variable = c_positive
  []
  [negative_inventory]
    type = ElementIntegralVariablePostprocessor
    variable = c_negative
  []
  [maximum_streamwise_velocity]
    type = ElementExtremeValue
    variable = velocity_x
    value_type = max
  []
[]

[Outputs]
  csv = true
  exodus = true
[]
