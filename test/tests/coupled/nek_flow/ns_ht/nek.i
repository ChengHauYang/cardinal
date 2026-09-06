[Mesh]
  type = NekRSMesh
  order = SECOND
  volume = true
[]

[Problem]
  type = NekRSProblem
  casename = ns_ht
  n_usrwrk_slots = 1
  skip_final_field_file = true

  [FieldTransfers]
    [temperature]
      type = NekFieldVariable
      field = temperature
      direction = to_nek
      usrwrk_slot = 0
    []
    [velocity_x]
      type = NekFieldVariable
      field = velocity_x
      direction = from_nek
    []
    [velocity_y]
      type = NekFieldVariable
      field = velocity_y
      direction = from_nek
    []
    [velocity_z]
      type = NekFieldVariable
      field = velocity_z
      direction = from_nek
    []
  []
[]

[Executioner]
  type = Transient

  [TimeStepper]
    type = NekTimeStepper
  []
[]

[Outputs]
  exodus = true
[]
